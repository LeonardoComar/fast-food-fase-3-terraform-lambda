terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

########################################
# IAM Role para a Lambda
########################################
resource "aws_iam_role" "lambda_exec" {
  name = "${var.lambda_name}-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Anexa política gerenciada básica de execução para logs CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

########################################
# Zip da função inline
########################################
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda_payload.zip"

  source {
    content  = <<-EOF
      def handler(event, context):
          return {
              "statusCode": 200,
              "headers": {"Content-Type": "application/json"},
              "body": "\"Estou aqui\""
          }
    EOF
    filename = "lambda_function.py"
  }
}

########################################
# Função Lambda
########################################
resource "aws_lambda_function" "auth" {
  function_name = var.lambda_name
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.9"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # Timeout/padronizações opcionais
  memory_size = 128
  timeout     = 5
}

########################################
# Integração da Lambda no API Gateway
# (assumindo que você já tem o API criado; aqui puxamos pelo ID)
########################################
data "aws_api_gateway_rest_api" "api" {
  name = var.api_gateway_name
}

# recurso proxy já existente? Caso queira uma rota específica:
resource "aws_api_gateway_resource" "lambda_auth" {
  rest_api_id = data.aws_api_gateway_rest_api.api.id
  parent_id   = data.aws_api_gateway_rest_api.api.root_resource_id
  path_part   = var.auth_path    # ex.: "auth"
}

resource "aws_api_gateway_method" "auth_any" {
  rest_api_id   = data.aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.lambda_auth.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "auth_lambda" {
  rest_api_id             = data.aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.lambda_auth.id
  http_method             = aws_api_gateway_method.auth_any.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${aws_lambda_function.auth.arn}/invocations"
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowInvokeFromAPIGW"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${data.aws_api_gateway_rest_api.api.execution_arn}/*/*/${var.auth_path}"
}

# Redeployment automático quando a integração mudar
resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [ aws_api_gateway_integration.auth_lambda ]

  rest_api_id = data.aws_api_gateway_rest_api.api.id
  triggers = {
    lambda_sha = sha1(data.archive_file.lambda_zip.output_base64sha256)
  }
}

resource "aws_api_gateway_stage" "stage" {
  rest_api_id   = data.aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.deployment.id
  stage_name    = var.stage_name
  auto_deploy   = true
}

########################################
# Outputs
########################################
output "lambda_arn" {
  value = aws_lambda_function.auth.arn
}

output "auth_api_invoke_url" {
  description = "URL para chamar a rota de auth"
  value = "${data.aws_api_gateway_rest_api.api.execution_arn}/${aws_api_gateway_stage.stage.stage_name}/${var.auth_path}"
}

########################################
# Variáveis
########################################
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "lambda_name" {
  type    = string
  default = "myapp-auth-lambda"
}

variable "api_gateway_name" {
  description = "Nome do API Gateway já criado"
  type        = string
}

variable "stage_name" {
  type    = string
  default = "prod"
}

variable "auth_path" {
  description = "Caminho na API para a Lambda (ex.: auth)"
  type        = string
  default     = "auth"
}
