##############################################
# 1. Provider, Data Sources e Variáveis Básicas
##############################################

provider "aws" {
  region = "us-east-1"
}

# Necessário para montar o source_arn no aws_lambda_permission
data "aws_caller_identity" "current" {}

# Exemplo de variável para o ALB do EKS
variable "alb_url" {
  description = "URL completa do ALB do EKS (incluindo porta). Ex: http://meu-alb-1234567890.us-east-1.elb.amazonaws.com:8080"
  type        = string
  default     = "http://a5c73036372f74af4909bbafe0099347-640925557.us-east-1.elb.amazonaws.com:8080"
}

# Role que você já tem criada no IAM e que sua Lambda deve usar
# (pode substituir pelo nome/ARN correto da role no seu ambiente)
variable "lambda_role_arn" {
  description = "ARN da IAM Role que a Lambda irá assumir (precisa ter trust policy para lambda.amazonaws.com e AWSLambdaBasicExecutionRole anexada)"
  type        = string
  default     = "arn:aws:iam::587167200064:role/RoleForLambdaModLabRole"
}

##############################################
# 2. HTTP API (API Gateway V2) – proxy para EKS
##############################################

# Cria um HTTP API que recebe requisições e repassa para o ALB
resource "aws_apigatewayv2_api" "eks_proxy_api" {
  name          = "eks-proxy-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "eks_backend" {
  api_id                 = aws_apigatewayv2_api.eks_proxy_api.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = var.alb_url
  payload_format_version = "1.0"
}

# NOTE: iremos reaproveitar essa rota para incorporar o authorizer
resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.eks_proxy_api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.eks_backend.id}"
  # Esses dois campos serão preenchidos após criarmos o Authorizer
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.lambda_auth.id
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.eks_proxy_api.id
  name        = "prod"
  auto_deploy = true
}

##############################################
# 3. Criação da Lambda (Python 3.13)
##############################################

resource "aws_lambda_function" "lambda_auth" {
  function_name = "lambdaAuth"
  filename      = "${path.module}/lambdaAuth.zip"
  handler       = "main.lambda_handler"
  runtime       = "python3.13"
  role          = var.lambda_role_arn

  # *** Atenção: verifique se seu zip contém exatamente main.py na raiz e
  #             se dentro dele há a definição `def lambda_handler(event, context): ...`
}

##############################################
# 4. Permissão para API Gateway invocar a Lambda
##############################################

# Permite que o API Gateway (principal: apigateway.amazonaws.com) invoque a função
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_auth.function_name
  principal     = "apigateway.amazonaws.com"

  # O source_arn precisa seguir o padrão:
  # arn:aws:execute-api:<region>:<account_id>:<api_id>/*/*
  # (asteriscos para abranger qualquer método e qualquer rota)
  source_arn = "arn:aws:execute-api:us-east-1:${data.aws_caller_identity.current.account_id}:${aws_apigatewayv2_api.eks_proxy_api.id}/*/*"
}

##############################################
# 5. Authorizer “CUSTOM” (REQUEST) apontando para a Lambda
##############################################

resource "aws_apigatewayv2_authorizer" "lambda_auth" {
  api_id          = aws_apigatewayv2_api.eks_proxy_api.id
  name            = "lambdaAuthAuthorizer"
  authorizer_type = "REQUEST"

  # URI no formato esperado para Lambda em HTTP API v2:
  authorizer_uri = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/${aws_lambda_function.lambda_auth.arn}/invocations"

  # De onde a Lambda irá extrair o token de autorização (header Authorization)
  identity_sources = ["$request.header.Authorization"]

  # Se quiser usar outros parts (querystring, path), poderia adicionar: 
  # identity_sources = ["$request.header.Authorization", "$request.querystring.token"]
}

##############################################
# 6. (Opcional) Saídas
##############################################

output "lambda_function_arn" {
  value = aws_lambda_function.lambda_auth.arn
}

output "http_api_endpoint" {
  value = aws_apigatewayv2_stage.prod.invoke_url
}
