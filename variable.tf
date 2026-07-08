variable "application_gateways" {
  type = map(object({
    resource_group_name = string
    app_gateway_name    = string
    vnet_name           = optional(string)
    subnet_name         = optional(string)
    public_ip_name      = optional(string)

    sku_settings = optional(object({
      name     = string
      tier     = string
      capacity = number
    }))

    # HTTPS(Key Vault 인증서) 사용 시 필요한 사용자 할당 관리 ID.
    # 이 ID에는 Key Vault 시크릿 읽기 권한(Key Vault Secrets User)이 미리 부여되어 있어야 한다.
    identity_ids = optional(list(string), [])

    # App GW에 등록할 SSL 인증서 목록 (Key Vault 참조 방식)
    # key: 인증서 이름 (리스너의 ssl_cert_key가 이 키를 참조)
    ssl_certificates = optional(map(object({
      key_vault_secret_id = string
    })), {})

    # 백엔드 풀. addresses에 IP와 FQDN을 섞어서 넣으면 main.tf에서 자동 분류된다.
    # 빈 리스트([])로 두면 빈 풀이 생성됨 (NIC association / VMSS 등 외부에서 멤버 관리 시).
    backend_pools = optional(map(object({
      addresses = optional(list(string), [])
    })), {})

    # 리스너. frontend_ports는 별도 변수 없이 여기 선언된 port에서 자동 유도된다.
    listeners = optional(map(object({
      port         = number
      protocol     = string                   # "Http" | "Https"
      host_name    = optional(string)         # 멀티사이트(같은 포트에 여러 리스너) 시 지정
      ssl_cert_key = optional(string)         # protocol이 Https면 필수. ssl_certificates의 키
    })), {})

    # 커스텀 헬스 프로브 (선택). backend_settings의 probe_key가 이 키를 참조.
    probes = optional(map(object({
      protocol            = string            # "Http" | "Https"
      path                = string            # 예: "/health"
      interval            = optional(number, 30)
      timeout             = optional(number, 30)
      unhealthy_threshold = optional(number, 3)
      host                = optional(string)  # 미지정 시 backend settings의 호스트를 따름
    })), {})

    backend_settings = optional(map(object({
      port            = number
      protocol        = string
      cookie_affinity = string
      request_timeout = optional(number, 30)
      probe_key       = optional(string)      # probes의 키. 미지정 시 기본 프로브 사용
    })), {})

    routing_rules = optional(map(object({
      rule_type    = string
      priority     = number
      listener_key = string                   # listeners의 키
      pool_key     = string                   # backend_pools의 키
      backend_key  = string                   # backend_settings의 키
    })), {})

    tags = optional(map(string), {})
  }))
  default = {}

  # ---- plan 단계에서 잡아주는 정합성 검증 ----

  validation {
    condition = alltrue(flatten([
      for gw in var.application_gateways : [
        for l in gw.listeners : l.protocol != "Https" || l.ssl_cert_key != null
      ]
    ]))
    error_message = "protocol이 \"Https\"인 리스너는 ssl_cert_key를 지정해야 합니다."
  }

  validation {
    condition = alltrue(flatten([
      for gw in var.application_gateways : [
        for l in gw.listeners :
        l.ssl_cert_key == null || contains(keys(gw.ssl_certificates), coalesce(l.ssl_cert_key, "_"))
      ]
    ]))
    error_message = "리스너의 ssl_cert_key가 ssl_certificates에 정의되지 않은 키를 참조하고 있습니다."
  }

  validation {
    condition = alltrue(flatten([
      for gw in var.application_gateways : [
        for r in gw.routing_rules : (
          contains(keys(gw.listeners), r.listener_key)
          && contains(keys(gw.backend_pools), r.pool_key)
          && contains(keys(gw.backend_settings), r.backend_key)
        )
      ]
    ]))
    error_message = "routing_rules의 listener_key / pool_key / backend_key는 각각 listeners / backend_pools / backend_settings에 존재하는 키여야 합니다."
  }

  validation {
    condition = alltrue(flatten([
      for gw in var.application_gateways : [
        for b in gw.backend_settings :
        b.probe_key == null || contains(keys(gw.probes), coalesce(b.probe_key, "_"))
      ]
    ]))
    error_message = "backend_settings의 probe_key가 probes에 정의되지 않은 키를 참조하고 있습니다."
  }

  validation {
    condition = alltrue([
      for gw in var.application_gateways :
      length(gw.ssl_certificates) == 0 || length(gw.identity_ids) > 0
    ])
    error_message = "ssl_certificates(Key Vault 참조)를 사용하려면 identity_ids에 관리 ID를 최소 1개 지정해야 합니다."
  }
}
