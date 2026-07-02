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

  sku {
    name     = each.value.sku_settings.name
    tier     = each.value.sku_settings.tier
    capacity = each.value.sku_settings.capacity
  }

  gateway_ip_configuration {
    name      = "${each.value.app_gateway_name}-ip-config"
    subnet_id = try(data.azurerm_subnet.subnet[each.key].id, null)
  }

  dynamic "frontend_port" {
    for_each = each.value.frontend_ports
    content {
      name = "${each.value.app_gateway_name}-port-${frontend_port.value}"
      port = frontend_port.value
    }
  }

  frontend_ip_configuration {
    name                 = "${each.value.app_gateway_name}-frontend-ip"
    public_ip_address_id = try(azurerm_public_ip.agw_pip[each.key].id, null)
  }

  backend_address_pool {
    name = "${each.value.app_gateway_name}-backend-pool"
  }

  dynamic "backend_http_settings" {
    for_each = each.value.backend_settings
    content {
      name                  = "${each.value.app_gateway_name}-${backend_http_settings.key}-http-settings"
      port                  = backend_http_settings.value.port
      protocol              = backend_http_settings.value.protocol
      cookie_based_affinity = backend_http_settings.value.cookie_affinity
    }
  }

  dynamic "http_listener" {
    for_each = each.value.listeners
    content {
      name                           = "${each.value.app_gateway_name}-${http_listener.key}-listener"
      frontend_ip_configuration_name = "${each.value.app_gateway_name}-frontend-ip"
      frontend_port_name             = "${each.value.app_gateway_name}-port-${http_listener.value.port}"
      protocol                       = http_listener.value.protocol
    }
  }

  dynamic "request_routing_rule" {
    for_each = each.value.routing_rules
    content {
      name      = "${each.value.app_gateway_name}-${request_routing_rule.key}-rule"
      rule_type = request_routing_rule.value.rule_type
      priority  = request_routing_rule.value.priority

      # 1. 리스너 연결
      http_listener_name = "${each.value.app_gateway_name}-${request_routing_rule.value.listener_key}-listener"

      # 2. 백엔드 풀 (보통 공통이므로 그대로 두거나, 필요시 변수화)
      backend_address_pool_name = "${each.value.app_gateway_name}-backend-pool"

      # 3. 핵심: 어떤 백엔드 설정을 쓸지 동적으로 매핑!
      backend_http_settings_name = "${each.value.app_gateway_name}-${request_routing_rule.value.backend_key}-http-settings"
    }
  }
}
