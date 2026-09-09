import json
import boto3
import os

# Initialize the DynamoDB client
dynamodb = boto3.resource('dynamodb')
table_name = os.environ.get('TABLE_NAME', 'cloud-resume-visitors')
table = dynamodb.Table(table_name)

def lambda_handler(event, context):
    """
    AWS Lambda function to increment and return a visitor count.
    """
    try:
        # Atomic update to increment the visitor count by 1
        response = table.update_item(
            Key={
                'id': 'visitor_count'
            },
            UpdateExpression='ADD visits :inc',
            ExpressionAttributeValues={
                ':inc': 1
            },
            ReturnValues='UPDATED_NEW'
        )
        
        # Extract the new count
        new_count = int(response['Attributes']['visits'])
        
        # Return CORS-enabled response
        return {
            'statusCode': 200,
            'headers': {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Content-Type',
                'Access-Control-Allow-Methods': 'OPTIONS,POST,GET'
            },
            'body': json.dumps({'visitor_count': new_count})
        }
    except Exception as e:
        print(f"Error updating DynamoDB: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Could not update visitor count'})
        }
