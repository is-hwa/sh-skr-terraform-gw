# ---------------------------------------------------------------------------
# 공통 로컬 값
# ---------------------------------------------------------------------------
locals {
  # IPv4 형식 판별용 정규식 (백엔드 풀 addresses 자동 분류에 사용)
  ipv4_regex = "^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$"
}

resource "azurerm_public_ip" "agw_pip" {
  for_each = {
    for k, v in var.application_gateways : k => v
    if v.public_ip_name != null
  }

  name                = each.value.public_ip_name
  resource_group_name = data.azurerm_resource_group.rg[each.value.resource_group_name].name
  location            = data.azurerm_resource_group.rg[each.value.resource_group_name].location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Application Gateway 생성 (게이트웨이마다 독립적으로 for_each)
resource "azurerm_application_gateway" "network" {
  for_each = {
    for k, v in var.application_gateways : k => v
    if v.sku_settings != null
  }

  name                = each.value.app_gateway_name
  resource_group_name = data.azurerm_resource_group.rg[each.value.resource_group_name].name
  location            = data.azurerm_resource_group.rg[each.value.resource_group_name].location
  tags                = each.value.tags

  sku {
    name     = each.value.sku_settings.name
    tier     = each.value.sku_settings.tier
    capacity = each.value.sku_settings.capacity
  }

  # Key Vault 인증서 조회에 사용할 관리 ID (HTTPS 미사용 시 블록 자체가 생성되지 않음)
  dynamic "identity" {
    for_each = length(each.value.identity_ids) > 0 ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = each.value.identity_ids
    }
  }

  gateway_ip_configuration {
    name      = "${each.value.app_gateway_name}-ip-config"
    subnet_id = try(data.azurerm_subnet.subnet[each.key].id, null)
  }

  # frontend_port는 별도 변수 없이 리스너에 선언된 포트에서 자동 유도.
  # -> "리스너에는 있는데 frontend_ports에 없다" 불일치가 원천적으로 발생하지 않음
  dynamic "frontend_port" {
    for_each = toset([for l in each.value.listeners : l.port])
    content {
      name = "${each.value.app_gateway_name}-port-${frontend_port.value}"
      port = frontend_port.value
    }
  }

  frontend_ip_configuration {
    name                 = "${each.value.app_gateway_name}-frontend-ip"
    public_ip_address_id = try(azurerm_public_ip.agw_pip[each.key].id, null)
  }

  # SSL 인증서 등록 (Key Vault 참조 방식).
  # 리스너의 ssl_certificate_name이 여기 name을 참조한다.
  # 사전 조건: identity_ids의 관리 ID에 해당 Key Vault의 시크릿 읽기 권한 필요
  #   (RBAC 모드: "Key Vault Secrets User" 역할 / access policy 모드: secret Get 권한)
  dynamic "ssl_certificate" {
    for_each = each.value.ssl_certificates
    content {
      name                = "${each.value.app_gateway_name}-${ssl_certificate.key}-cert"
      key_vault_secret_id = ssl_certificate.value.key_vault_secret_id
    }
  }

  # 백엔드 풀 다중화. addresses에 IP/FQDN을 섞어 넣으면 자동 분류.
  # addresses가 빈 리스트면 빈 풀 생성 (외부에서 멤버를 관리하는 패턴).
  # 주의: NIC association / VMSS / AGIC 등 외부에서 풀 멤버를 관리한다면
  #       아래 lifecycle 주석 참고 (ignore_changes 필요).
  dynamic "backend_address_pool" {
    for_each = each.value.backend_pools
    content {
      name = "${each.value.app_gateway_name}-${backend_address_pool.key}-pool"

      ip_addresses = [
        for addr in backend_address_pool.value.addresses : addr
        if can(regex(local.ipv4_regex, addr))
      ]

      fqdns = [
        for addr in backend_address_pool.value.addresses : addr
        if !can(regex(local.ipv4_regex, addr))
      ]
    }
  }

  # 커스텀 헬스 프로브 (선택)
  dynamic "probe" {
    for_each = each.value.probes
    content {
      name                                      = "${each.value.app_gateway_name}-${probe.key}-probe"
      protocol                                  = probe.value.protocol
      path                                      = probe.value.path
      interval                                  = probe.value.interval
      timeout                                   = probe.value.timeout
      unhealthy_threshold                       = probe.value.unhealthy_threshold
      host                                      = probe.value.host
      # host 미지정 시 backend http settings의 호스트를 사용
      pick_host_name_from_backend_http_settings = probe.value.host == null
    }
  }

  dynamic "backend_http_settings" {
    for_each = each.value.backend_settings
    content {
      name                  = "${each.value.app_gateway_name}-${backend_http_settings.key}-http-settings"
      port                  = backend_http_settings.value.port
      protocol              = backend_http_settings.value.protocol
      cookie_based_affinity = backend_http_settings.value.cookie_affinity
      request_timeout       = backend_http_settings.value.request_timeout
      probe_name = (
        backend_http_settings.value.probe_key != null
        ? "${each.value.app_gateway_name}-${backend_http_settings.value.probe_key}-probe"
        : null
      )
    }
  }

  # 리스너.
  # - host_name 지정 시 같은 포트에 여러 리스너(멀티사이트) 구성 가능
  # - Https 리스너는 ssl_cert_key로 위 ssl_certificate 블록을 참조
  #   (null이면 속성을 넣지 않은 것과 동일하게 처리되므로 기존 Http 리스너와 하위 호환)
  dynamic "http_listener" {
    for_each = each.value.listeners
    content {
      name                           = "${each.value.app_gateway_name}-${http_listener.key}-listener"
      frontend_ip_configuration_name = "${each.value.app_gateway_name}-frontend-ip"
      frontend_port_name             = "${each.value.app_gateway_name}-port-${http_listener.value.port}"
      protocol                       = http_listener.value.protocol
      host_name                      = http_listener.value.host_name
      ssl_certificate_name = (
        http_listener.value.ssl_cert_key != null
        ? "${each.value.app_gateway_name}-${http_listener.value.ssl_cert_key}-cert"
        : null
      )
    }
  }

  # 라우팅 룰: 리스너 / 풀 / 백엔드 설정을 모두 키로 매핑
  dynamic "request_routing_rule" {
    for_each = each.value.routing_rules
    content {
      name      = "${each.value.app_gateway_name}-${request_routing_rule.key}-rule"
      rule_type = request_routing_rule.value.rule_type
      priority  = request_routing_rule.value.priority

      http_listener_name         = "${each.value.app_gateway_name}-${request_routing_rule.value.listener_key}-listener"
      backend_address_pool_name  = "${each.value.app_gateway_name}-${request_routing_rule.value.pool_key}-pool"
      backend_http_settings_name = "${each.value.app_gateway_name}-${request_routing_rule.value.backend_key}-http-settings"
    }
  }

  # -------------------------------------------------------------------------
  # [주의] 풀 멤버를 이 모듈 밖에서 관리하는 경우 (NIC association, VMSS, AGIC 등)
  # 아래 lifecycle 블록의 주석을 해제할 것. 해제하지 않으면 다음 apply 때
  # Terraform이 외부에서 등록된 멤버를 전부 제거한다.
  # 반대로 backend_pools.addresses로 멤버를 직접 관리한다면 절대 해제하지 말 것.
  # (ignore_changes는 변수로 조건 분기가 불가능해 주석 토글로만 제어 가능)
  # -------------------------------------------------------------------------
  # lifecycle {
  #   ignore_changes = [backend_address_pool]
  # }
}
