# Azure Application Gateway Terraform Automation

Azure Application Gateway를 요청 단위(Request 기반)로 생성·수정·삭제할 수 있도록 구성한 Terraform 모듈과, 이를 Azure DevOps 파이프라인으로 자동화한 프로젝트입니다.

## 개요

여러 Application Gateway를 하나의 Terraform state에서 `for_each`로 관리하되, 실제 운영에서는 각 요청(REQUEST_ID)마다 하나의 Gateway 스펙만 전달받아 기존 상태(tfvars)에 병합하는 방식으로 동작합니다. 파이프라인은 변수 병합 → Init → Plan → 승인 → Apply 순으로 진행되며, 각 단계 결과를 외부 API로 콜백 전송합니다.

## 파일 구성

| 파일 | 역할 |
|---|---|
| `provider.tf` | azurerm provider(4.74.0) 및 local backend 선언. 파이프라인에서 `backend.hcl`로 backend 설정을 override |
| `variable.tf` | `application_gateways` 변수 정의 (map(object)). Gateway별 이름, 네트워크, SKU, 리스너, 백엔드, 라우팅 규칙 스펙 |
| `data.tf` | 기존 Resource Group / Subnet 조회 (data source) |
| `main.tf` | Public IP, Application Gateway 리소스 정의. 리스너·백엔드 설정·라우팅 규칙을 `dynamic` 블록으로 생성 |
| `azure-pipelines.yml` | 요청 기반 tfvars 병합 → Terraform Init/Plan/Apply → 결과 콜백을 수행하는 Azure DevOps 파이프라인 |

## 변수 구조 (`application_gateways`)

```hcl
application_gateways = {
  "<key>" = {
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
    frontend_ports    = optional(list(number))
    listeners         = optional(map(object({ port = number, protocol = string })))
    backend_settings  = optional(map(object({ port = number, protocol = string, cookie_affinity = string })))
    routing_rules     = optional(map(object({
      rule_type    = string
      listener_key = string
      backend_key  = string
      priority     = number
    })))
  }
}
```

- 리소스 이름은 모두 `app_gateway_name` 기준으로 접미사를 붙여 생성됩니다 (`{name}-frontend-ip`, `{name}-{key}-listener` 등).
- `sku_settings`가 없는 항목은 Application Gateway 리소스 생성 대상에서 제외됩니다.

## 파이프라인 동작 흐름

파이프라인은 `REQUEST_ID`, `PROJECT`, `ACTION`(create/update/delete), `ENV`, `VARIABLE`(단일 Gateway 스펙 JSON)을 파라미터로 받아 실행됩니다.

1. **Prepare**
   - 요청으로 들어온 `VARIABLE`을 `terraform.tfvars.json`으로 저장
   - `STATE_DIR`(환경/프로젝트별 경로)에 저장된 기존 `app-gw.auto.tfvars.json`을 불러와 `merged.json`으로 복사 (없으면 빈 맵으로 초기화)
   - `ACTION`이 `delete`면 병합본에서 해당 key 제거, 그 외에는 upsert
   - 병합 결과를 `backend.hcl`(state 경로)과 함께 작업 디렉토리에 저장
2. **Init** — `backend.hcl`을 사용해 `terraform init` (state는 Blob 등 원격 backend 경로로 지정)
3. **Plan** — 병합된 tfvars로 `terraform plan` 수행, 결과를 `tfplan.json`으로 저장
4. **NotifyPlanSuccess** — Plan 결과를 외부 API(`/api/plan/success`)로 전송
5. **Apply** — `terraform-apply-approval` 환경 승인 후 `terraform apply` 수행, 적용된 tfvars를 `STATE_DIR`에 다시 저장(다음 요청의 병합 기준이 됨)
6. **NotifyApplySuccess** — 최종 성공을 `/api/pipeline/success`로 전송
7. **HandleFailure** — 앞 단계 중 하나라도 실패하면 `error.log`를 읽어 `/api/pipeline/failed`로 실패 사유 전송

## 상태 관리 방식

- Terraform state 자체는 `STATE_DIR/terraform.tfstate` 경로를 backend로 사용
- 병합용 tfvars 스냅샷(`app-gw.auto.tfvars.json`)을 별도로 `STATE_DIR`에 두어, 다음 요청이 들어올 때 "현재 관리 중인 Gateway 목록"의 소스가 되도록 함
- 즉 한 번에 하나의 Gateway 요청만 받아도 전체 맵을 유지·재구성하는 구조

## 참고 / 제약 사항

- `provider.tf`의 backend는 `local`로 선언되어 있으나, 파이프라인의 `terraform init -backend-config=backend.hcl`을 통해 실제 경로가 주입됨 (원격 backend로 전환 시 `backend "local" {}` → 해당 backend 타입으로 변경 필요)
- 알림 API 엔드포인트(`13.124.121.66:8000`)는 하드코딩되어 있어 환경별 분리가 필요할 경우 변수화 권장
- Public IP 이름 변경 시 `ApplicationGatewayFrontendIpPublicIpAddressCannotBeChanged` 오류가 발생할 수 있으며, 테스트 환경에서는 `terraform apply -replace`로 해결 가능
