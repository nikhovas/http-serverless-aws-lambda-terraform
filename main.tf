terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.48.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.2.0"
    }
  }

  required_version = "~> 1.0"
}

variable "aws_region" {
  description = "AWS region for all resources."

  type    = string
  default = "us-east-1"
}

provider "aws" {
  region = var.aws_region
}

# Storing lambda function code as archive
data "archive_file" "lambda_code_archive" {
  type        = "zip"
  source_file = "${path.module}/main.py"
  output_path = "${path.module}/main.zip"
}

# Lambda function definition
resource "aws_lambda_function" "http_request_details_lambda" {
  function_name    = "HttpRequestDetails"
  filename         = data.archive_file.lambda_code_archive.output_path
  runtime          = "python3.8"
  handler          = "main.handler"
  source_code_hash = data.archive_file.lambda_code_archive.output_base64sha256
  role             = aws_iam_role.lambda_exec.arn

  environment {
    variables = {
      foo = "bar"
    }
  }
}

# Log group for lambda function
# Lambda stores logs by default at /aws/lambda/{function_name}
resource "aws_cloudwatch_log_group" "http_request_details_log" {
  name              = "/aws/lambda/${aws_lambda_function.http_request_details_lambda.function_name}"
  retention_in_days = 30
}

output "function_name" {
  description = "Name of the Lambda function."
  value       = aws_lambda_function.http_request_details_lambda.function_name
}

# User for lambda
# When lambda will be executing, it'll do it from this user
resource "aws_iam_role" "lambda_exec" {
  name = "serverless_lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Sid    = ""
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      }
    ]
  })
}

# Attaching role to lambda user
resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" # Allow to write CloudWatch logs
}

# Api Gateway definition
resource "aws_apigatewayv2_api" "lambda" {
  name          = "serverless_lambda_gw"
  protocol_type = "HTTP"
}

# Api stage manager (using for dev, prod, beta, etc stages)
resource "aws_apigatewayv2_stage" "lambda" {
  api_id      = aws_apigatewayv2_api.lambda.id
  name        = "serverless_lambda_stage"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format          = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      protocol                = "$context.protocol"
      httpMethod              = "$context.httpMethod"
      resourcePath            = "$context.resourcePath"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
      }
    )
  }
}

# connect ApiGateway to lambda
resource "aws_apigatewayv2_integration" "hello_world" {
  api_id             = aws_apigatewayv2_api.lambda.id
  integration_uri    = aws_lambda_function.http_request_details_lambda.invoke_arn
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
}

# Declare endpoint and connect to lambda
resource "aws_apigatewayv2_route" "hello_world" {
  api_id    = aws_apigatewayv2_api.lambda.id
  route_key = "GET /request-info"
  target    = "integrations/${aws_apigatewayv2_integration.hello_world.id}"
}

# LogGroup for ApiGateway
resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/api_gw/${aws_apigatewayv2_api.lambda.name}"
  retention_in_days = 30
}

# Allow ApiGateway to use lambda function
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.http_request_details_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.lambda.execution_arn}/*/*"
}

output "base_url" {
  description = "Base URL for API Gateway stage."
  value       = aws_apigatewayv2_stage.lambda.invoke_url
}