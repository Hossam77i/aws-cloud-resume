import json
import boto3
import os

dynamodb = boto3.resource('dynamodb')
table_name = os.environ.get('THREAT_TABLE', 'cloud-resume-threats')
table = dynamodb.Table(table_name)

def lambda_handler(event, context):
    try:
        # Scan the table (in production use Query with an index, but Scan is fine for small demo)
        response = table.scan(Limit=50)
        items = response.get('Items', [])
        
        # Sort by timestamp descending and take top 5
        items.sort(key=lambda x: x.get('timestamp', 0), reverse=True)
        recent_threats = items[:5]
        
        return {
            'statusCode': 200,
            'headers': {
                'Access-Control-Allow-Origin': '*',
                'Content-Type': 'application/json'
            },
            'body': json.dumps({'threats': recent_threats})
        }
    except Exception as e:
        print(f"Error fetching threats: {e}")
        return {'statusCode': 500, 'body': json.dumps({'error': 'Failed to fetch telemetry'})}
