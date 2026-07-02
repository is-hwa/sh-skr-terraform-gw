variable "application_gateways" {
  type = map(object({
    resource_group_name = string
    app_gateway_name     = string
    vnet_name            = optional(string)
    subnet_name          = optional(string)
    public_ip_name       = optional(string)

    sku_settings = optional(object({
      name     = string
      tier     = string
      capacity = number
    }))

    frontend_ports = optional(list(number), [])

    listeners = optional(map(object({
      port     = number
      protocol = string
    })), {})

    backend_settings = optional(map(object({
      port            = number
      protocol        = string
      cookie_affinity = string
    })), {})

    routing_rules = optional(map(object({
      rule_type    = string
      listener_key = string
      backend_key  = string
      priority     = number
    })), {})
  }))
  default = {}
}
