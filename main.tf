##############################################
# 1. Provider e variáveis básicas
##############################################

provider "aws" {
  region = "us-east-1"
}

# Você pode parametrizar a URL do seu ALB (com porta) em variável, para facilitar alterações futuras.
variable "alb_url" {
  description = "URL completa do ALB do EKS (incluindo porta). Ex: http://meu-alb-1234567890.us-east-1.elb.amazonaws.com:8080"
  type        = string
  default     = "http://a5c73036372f74af4909bbafe0099347-640925557.us-east-1.elb.amazonaws.com:8080"
}


##############################################
# 2. Criação do HTTP API (API Gateway V2)
##############################################

# Cria um HTTP API que receberá as requisições
resource "aws_apigatewayv2_api" "eks_proxy_api" {
  name          = "eks-proxy-api"
  protocol_type = "HTTP"

  # (Opcional) CORS se você precisar que diferentes domínios consumam sua API
  # cors_configuration {
  #   allow_origins = ["*"]
  #   allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"]
  #   allow_headers = ["*"]
  # }
}


##############################################
# 3. Integração HTTP_PROXY com o ALB do EKS
##############################################

# Cria a integração que aponta para o seu ALB (EKS)
resource "aws_apigatewayv2_integration" "eks_backend" {
  api_id                 = aws_apigatewayv2_api.eks_proxy_api.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = var.alb_url
  payload_format_version = "1.0"

  # Observações:
  # - Com HTTP_PROXY + "$default" (rota padrão), todo o path e query string que chegar no API Gateway
  #   serão repassados para o seu ALB exatamente como vier.
  # - Se você quiser filtrar apenas determinados caminhos, seria preciso criar routes específicas
  #   em vez de usar $default.
}


##############################################
# 4. Rota padrão (proxy all)
##############################################

# Ao usar `$default`, o API Gateway não exige rota explícita para cada path.
# Toda requisição (independente do método e do caminho) será direcionada a `aws_apigatewayv2_integration.eks_backend`.
resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.eks_proxy_api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.eks_backend.id}"
}


##############################################
# 5. Deployment / Stage
##############################################

# Opcionalmente, você pode criar um estágio separado para “produção”, “homolog”, etc.
resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.eks_proxy_api.id
  name        = "prod"
  auto_deploy = true

  # Variáveis de ambiente (caso queira repassar alguma coisa ao backend)
  # default_route_settings {
  #   logging_level = "INFO"
  #   data_trace_enabled = true
  # }

  # Se não quiser versionamento, basta manter o auto_deploy = true,
  # assim qualquer mudança no `route` ou `integration` já entra no ar.
}


##############################################
# 6. (Opcional) Permissões de CORS ou Autorizadores
##############################################

# Caso precise liberar CORS, você pode descomentar o bloco cors_configuration no recurso aws_apigatewayv2_api.
# Se quiser adicionar um Authorizer (JWT, Lambda, etc.), seria algo assim:

# resource "aws_apigatewayv2_authorizer" "jwt_auth" {
#   name                   = "jwt-auth"
#   api_id                 = aws_apigatewayv2_api.eks_proxy_api.id
#   authorizer_type        = "JWT"
#   identity_sources       = ["$request.header.Authorization"]
#   jwt_configuration {
#     issuer = "https://cognito-idp.us-east-1.amazonaws.com/xxxxxx"
#     audience = ["xxxxxxxxxx"]
#   }
# }

# Depois, vincule o authorizer à rota:
# resource "aws_apigatewayv2_route" "default_route" {
#   api_id    = aws_apigatewayv2_api.eks_proxy_api.id
#   route_key = "$default"
#   target    = "integrations/${aws_apigatewayv2_integration.eks_backend.id}"
#   authorization_type = "JWT"
#   authorizer_id      = aws_apigatewayv2_authorizer.jwt_auth.id
# }


##############################################
# 7. Como funciona na prática
#
# Após rodar `terraform apply`, você terá:
#  - Um endpoint HTTP em:
#      https://<your-api-id>.execute-api.us-east-1.amazonaws.com/prod
#  - Qualquer requisição enviada para esse endpoint (GET, POST, PUT, DELETE, etc),
#    em qualquer caminho (e.g. /products, /clients/123, /foo/bar?x=1), será
#    automaticamente repassada ao ALB: http://a5c73036…amazonaws.com:8080/{proxy}
#
# Exemplos:
#  - GET  https://<api-id>.execute-api.us-east-1.amazonaws.com/prod/products
#     → proxy → GET http://a5c73036…amazonaws.com:8080/products
#
#  - POST https://<api-id>.execute-api.us-east-1.amazonaws.com/prod/clients
#     → proxy → POST http://a5c73036…amazonaws.com:8080/clients
#
#  - PUT  https://<api-id>.execute-api.us-east-1.amazonaws.com/prod/orders/55
#     → proxy → PUT http://a5c73036…amazonaws.com:8080/orders/55
#
# Assim, não é preciso definir cada rota isoladamente: o "$default" cobre tudo.
##############################################
