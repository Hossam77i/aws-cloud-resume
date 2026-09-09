import json
import boto3
import os
import time
import uuid

dynamodb = boto3.resource('dynamodb')
table_name = os.environ.get('THREAT_TABLE', 'cloud-resume-threats')
table = dynamodb.Table(table_name)

def lambda_handler(event, context):
    try:
        # Extract attacker telemetry
        request_context = event.get('requestContext', {})
        headers = event.get('headers', {})
        
        source_ip = request_context.get('http', {}).get('sourceIp', 'Unknown IP')
        user_agent = headers.get('user-agent', 'Unknown User-Agent')
        payload = event.get('body', '')

        # Log the threat to DynamoDB
        table.put_item(
            Item={
                'id': str(uuid.uuid4()),
                'timestamp': int(time.time()),
                'ip': source_ip,
                'user_agent': user_agent[:100], # truncate just in case
                'payload': payload[:200]
            }
        )
        
        # Return a fake error to keep the scanner guessing
        return {
            'statusCode': 401,
            'headers': {
                'Access-Control-Allow-Origin': '*',
                'Content-Type': 'application/json'
            },
            'body': json.dumps({'status': 'error', 'message': 'Invalid admin credentials or missing MFA token.'})
        }
    except Exception as e:
        print(f"Honeypot Error: {e}")
        return {'statusCode': 500}
