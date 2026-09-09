import boto3
import json
import zipfile
import os
import time

def deploy():
    print("Deploying Cloud Resume Infrastructure...")
    
    # Clients
    dynamodb = boto3.client('dynamodb', region_name='us-east-1')
    iam = boto3.client('iam', region_name='us-east-1')
    lambda_client = boto3.client('lambda', region_name='us-east-1')
    apigw = boto3.client('apigatewayv2', region_name='us-east-1')

    # 1. DynamoDB
    table_name = "cloud-resume-visitors"
    try:
        dynamodb.describe_table(TableName=table_name)
        print(f"Table {table_name} already exists.")
    except dynamodb.exceptions.ResourceNotFoundException:
        print(f"Creating DynamoDB table {table_name}...")
        dynamodb.create_table(
            TableName=table_name,
            KeySchema=[{'AttributeName': 'id', 'KeyType': 'HASH'}],
            AttributeDefinitions=[{'AttributeName': 'id', 'AttributeType': 'S'}],
            BillingMode='PAY_PER_REQUEST'
        )
        time.sleep(5)

    # 2. IAM Role
    role_name = "cloud_resume_lambda_role"
    try:
        role = iam.get_role(RoleName=role_name)
        print(f"Role {role_name} already exists.")
    except iam.exceptions.NoSuchEntityException:
        print(f"Creating IAM role {role_name}...")
        assume_role_policy = {
            "Version": "2012-10-17",
            "Statement": [{"Action": "sts:AssumeRole", "Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}}]
        }
        iam.create_role(RoleName=role_name, AssumeRolePolicyDocument=json.dumps(assume_role_policy))
        iam.attach_role_policy(RoleName=role_name, PolicyArn="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole")
        iam.attach_role_policy(RoleName=role_name, PolicyArn="arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess")
        time.sleep(10) # Wait for role to propagate
    
    role = iam.get_role(RoleName=role_name)
    role_arn = role['Role']['Arn']

    # 3. Zip Lambda
    zip_path = "/tmp/lambda.zip"
    with zipfile.ZipFile(zip_path, 'w') as zf:
        zf.write("backend/lambda_function.py", arcname="lambda_function.py")

    # 4. Lambda Function
    func_name = "cloud_resume_visitor_counter"
    try:
        lambda_client.get_function(FunctionName=func_name)
        print(f"Lambda {func_name} exists, updating code...")
        with open(zip_path, 'rb') as f:
            lambda_client.update_function_code(FunctionName=func_name, ZipFile=f.read())
    except lambda_client.exceptions.ResourceNotFoundException:
        print(f"Creating Lambda {func_name}...")
        with open(zip_path, 'rb') as f:
            lambda_client.create_function(
                FunctionName=func_name,
                Runtime='python3.10',
                Role=role_arn,
                Handler='lambda_function.lambda_handler',
                Code={'ZipFile': f.read()},
                Environment={'Variables': {'TABLE_NAME': table_name}}
            )

    func_arn = lambda_client.get_function(FunctionName=func_name)['Configuration']['FunctionArn']

    # 5. API Gateway
    print("Setting up API Gateway...")
    apis = apigw.get_apis()['Items']
    api_id = next((a['ApiId'] for a in apis if a['Name'] == 'cloud_resume_api'), None)
    
    if not api_id:
        api = apigw.create_api(
            Name='cloud_resume_api',
            ProtocolType='HTTP',
            CorsConfiguration={'AllowOrigins': ['*'], 'AllowMethods': ['GET', 'POST', 'OPTIONS'], 'AllowHeaders': ['content-type']}
        )
        api_id = api['ApiId']
        print(f"Created API {api_id}")
    
    # Integration
    integrations = apigw.get_integrations(ApiId=api_id)['Items']
    integration_id = next((i['IntegrationId'] for i in integrations if i['IntegrationUri'] == func_arn), None)
    if not integration_id:
        integration = apigw.create_integration(
            ApiId=api_id,
            IntegrationType='AWS_PROXY',
            IntegrationUri=func_arn,
            IntegrationMethod='POST',
            PayloadFormatVersion='2.0'
        )
        integration_id = integration['IntegrationId']
    
    # Route
    routes = apigw.get_routes(ApiId=api_id)['Items']
    route_key = "POST /visitor"
    if not any(r['RouteKey'] == route_key for r in routes):
        apigw.create_route(ApiId=api_id, RouteKey=route_key, Target=f"integrations/{integration_id}")

    # Stage
    stages = apigw.get_stages(ApiId=api_id)['Items']
    if not any(s['StageName'] == '$default' for s in stages):
        apigw.create_stage(ApiId=api_id, StageName='$default', AutoDeploy=True)

    # Permissions
    try:
        lambda_client.add_permission(
            FunctionName=func_name,
            StatementId='apigw-invoke',
            Action='lambda:InvokeFunction',
            Principal='apigateway.amazonaws.com',
            SourceArn=f"arn:aws:execute-api:us-east-1:*:{api_id}/*"
        )
    except lambda_client.exceptions.ResourceConflictException:
        pass # Permission exists

    api_url = f"https://{api_id}.execute-api.us-east-1.amazonaws.com/visitor"
    print(f"\n✅ DEPLOYMENT SUCCESSFUL!")
    print(f"API Endpoint: {api_url}")
    print("Update your frontend/index.html with this URL!")

if __name__ == "__main__":
    deploy()
