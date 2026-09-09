provider "aws" {
  region = "us-east-1"
}

# ------------------------------------------------------
# 1. DYNAMODB TABLE
# ------------------------------------------------------
resource "aws_dynamodb_table" "visitor_table" {
  name           = "cloud-resume-visitors"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# ------------------------------------------------------
# 2. IAM ROLE FOR LAMBDA
# ------------------------------------------------------
resource "aws_iam_role" "lambda_exec_role" {
  name = "cloud_resume_lambda_role"

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

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "dynamodb_access_policy" {
  name        = "lambda_dynamodb_access"
  description = "Allow Lambda to read/write to DynamoDB visitor table"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "dynamodb:UpdateItem",
        "dynamodb:GetItem",
        "dynamodb:PutItem"
      ]
      Effect   = "Allow"
      Resource = aws_dynamodb_table.visitor_table.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.dynamodb_access_policy.arn
}

# ------------------------------------------------------
# 3. LAMBDA FUNCTION
# ------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../backend/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "visitor_counter" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "cloud_resume_visitor_counter"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.10"

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.visitor_table.name
    }
  }
}

# ------------------------------------------------------
# 4. API GATEWAY (HTTP API)
# ------------------------------------------------------
resource "aws_apigatewayv2_api" "http_api" {
  name          = "cloud_resume_api"
  protocol_type = "HTTP"
  
  cors_configuration {
    allow_origins = ["*"] # We will restrict this to your S3 bucket domain later
    allow_methods = ["POST", "GET", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  
  integration_uri    = aws_lambda_function.visitor_counter.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "post_visitor_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /visitor"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_lambda_permission" "api_gw_invoke" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_counter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# ------------------------------------------------------
# 5. OUTPUTS
# ------------------------------------------------------
output "api_endpoint" {
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/visitor"
  description = "The URL to invoke your Lambda function"
}

# ------------------------------------------------------
# 6. S3 BUCKET FOR FRONTEND HOSTING
# ------------------------------------------------------
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "resume_frontend" {
  bucket = "hossam-cloud-resume-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket_website_configuration" "resume_website" {
  bucket = aws_s3_bucket.resume_frontend.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket = aws_s3_bucket.resume_frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "public_read" {
  bucket     = aws_s3_bucket.resume_frontend.id
  depends_on = [aws_s3_bucket_public_access_block.public_access]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.resume_frontend.arn}/*"
      },
    ]
  })
}

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.resume_frontend.id
  key          = "index.html"
  source       = "${path.module}/../frontend/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/../frontend/index.html")
}

output "website_url" {
  value       = aws_s3_bucket_website_configuration.resume_website.website_endpoint
  description = "The public URL to view and share your cloud resume"
}

# ------------------------------------------------------
# 7. HONEYPOT INFRASTRUCTURE
# ------------------------------------------------------
resource "aws_dynamodb_table" "threats_table" {
  name           = "cloud-resume-threats"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_iam_policy" "threat_dynamodb_access" {
  name        = "lambda_threats_dynamodb_access"
  description = "Allow Lambda to read/write to threats table"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = ["dynamodb:Scan", "dynamodb:PutItem"]
      Effect   = "Allow"
      Resource = aws_dynamodb_table.threats_table.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "threat_dynamodb_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.threat_dynamodb_access.arn
}

# --- Honeypot Lambda ---
data "archive_file" "honeypot_zip" {
  type        = "zip"
  source_file = "${path.module}/../backend/honeypot.py"
  output_path = "${path.module}/honeypot.zip"
}

resource "aws_lambda_function" "honeypot" {
  filename         = data.archive_file.honeypot_zip.output_path
  function_name    = "cloud_resume_honeypot"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "honeypot.lambda_handler"
  source_code_hash = data.archive_file.honeypot_zip.output_base64sha256
  runtime          = "python3.10"
  environment { variables = { THREAT_TABLE = aws_dynamodb_table.threats_table.name } }
}

# --- Get Threats Lambda ---
data "archive_file" "get_threats_zip" {
  type        = "zip"
  source_file = "${path.module}/../backend/get_threats.py"
  output_path = "${path.module}/get_threats.zip"
}

resource "aws_lambda_function" "get_threats" {
  filename         = data.archive_file.get_threats_zip.output_path
  function_name    = "cloud_resume_get_threats"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "get_threats.lambda_handler"
  source_code_hash = data.archive_file.get_threats_zip.output_base64sha256
  runtime          = "python3.10"
  environment { variables = { THREAT_TABLE = aws_dynamodb_table.threats_table.name } }
}

# --- API Gateway Routes ---
resource "aws_apigatewayv2_integration" "honeypot_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.honeypot.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "honeypot_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /api/v1/admin/auth"
  target    = "integrations/${aws_apigatewayv2_integration.honeypot_integration.id}"
}

resource "aws_lambda_permission" "honeypot_invoke" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.honeypot.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "get_threats_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.get_threats.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "get_threats_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /threats"
  target    = "integrations/${aws_apigatewayv2_integration.get_threats_integration.id}"
}

resource "aws_lambda_permission" "get_threats_invoke" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_threats.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

output "honeypot_url" {
  value = "${aws_apigatewayv2_api.http_api.api_endpoint}/api/v1/admin/auth"
}
output "threats_api_url" {
  value = "${aws_apigatewayv2_api.http_api.api_endpoint}/threats"
}
