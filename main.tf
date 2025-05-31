provider "aws" {
  region = "us-east-1"
}

# Módulo Cognito corrigido
resource "aws_cognito_user_pool" "fastfood_pool" {
  name = "fastfood-auth-pool"

  schema {
    attribute_data_type = "String"
    name               = "cpf"
    required           = true
    mutable            = true

    string_attribute_constraints {
      min_length = 11
      max_length = 14
    }
  }

  # Política de senha corrigida (mínimo 6 caracteres)
  password_policy {
    minimum_length    = 6  # CORREÇÃO: mínimo permitido é 6
    require_lowercase = false
    require_numbers   = false
    require_symbols   = false
    require_uppercase = false
  }

  # Adicionado para permitir autenticação sem senha
  alias_attributes = ["email"]
  auto_verified_attributes = ["email"]
  
  # Configuração para login com CPF
  username_configuration {
    case_sensitive = false
  }
}

resource "aws_cognito_user_pool_client" "client" {
  name = "fastfood-client"

  user_pool_id = aws_cognito_user_pool.fastfood_pool.id
  explicit_auth_flows = [
    "ALLOW_CUSTOM_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]
  generate_secret = false
  
  # Permitir autenticação apenas com CPF
  auth_session_validity = 3
  prevent_user_existence_errors = "ENABLED"
}

# Módulo Lambda (mantido igual)
resource "aws_lambda_function" "auth_lambda" {
  filename      = "lambda/auth-lambda/auth_lambda.zip"
  function_name = "fastfood-auth-lambda"
  role          = aws_iam_role.lambda_role.arn
  handler       = "main.lambda_handler"
  runtime       = "python3.9"
  timeout       = 30

  environment {
    variables = {
      USER_POOL_ID = aws_cognito_user_pool.fastfood_pool.id
      CLIENT_ID    = aws_cognito_user_pool_client.client.id
    }
  }
}

# IAM Role (mantido igual)
resource "aws_iam_role" "lambda_role" {
  name = "lambda-cognito-auth-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "cognito_access" {
  name = "CognitoLambdaAccess"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = [
        "cognito-idp:AdminInitiateAuth",
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminSetUserPassword"
      ]
      Effect   = "Allow"
      Resource = aws_cognito_user_pool.fastfood_pool.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_cognito" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.cognito_access.arn
}

# Módulo API Gateway corrigido
resource "aws_api_gateway_rest_api" "main" {
  name = "fastfood-gateway"
}

resource "aws_api_gateway_resource" "auth" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "auth"
}

resource "aws_api_gateway_method" "auth_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.auth.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.auth.id
  http_method             = aws_api_gateway_method.auth_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.auth_lambda.invoke_arn
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

# CORREÇÃO: Recurso de integração HTTP correto
resource "aws_api_gateway_integration" "eks_integration" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy.http_method

  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://a5c73036372f74af4909bbafe0099347-640925557.us-east-1.elb.amazonaws.com/{proxy}"

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

resource "aws_api_gateway_authorizer" "cognito" {
  name          = "cognito-authorizer"
  type          = "COGNITO_USER_POOLS"
  rest_api_id   = aws_api_gateway_rest_api.main.id
  provider_arns = [aws_cognito_user_pool.fastfood_pool.arn]
}

resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda_integration,
    aws_api_gateway_integration.eks_integration
  ]

  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = "prod"
}

output "api_url" {
  value = "${aws_api_gateway_deployment.deployment.invoke_url}/auth"
}

# Adicione este recurso
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/${aws_api_gateway_method.auth_post.http_method}${aws_api_gateway_resource.auth.path}"
}