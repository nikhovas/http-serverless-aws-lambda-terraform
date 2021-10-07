import json
import os


def handler(event, context):
    return {
        'statusCode': 200,
        'body': json.dumps({
            'eventData': event,
            'eventType': type(event).__name__,
            'contextType': type(context).__name__,
            'requestId': context.aws_request_id,
            'memoryLimitMb': context.memory_limit_in_mb,
            'envs': dict(os.environ)
        })
    }