#!/usr/bin/env bash
# ЛР-8: той самий сценарій розгортання для Linux/macOS/WSL (потрібні aws CLI і zip).
#   docker compose -f aws/docker-compose.yml up -d
#   bash aws/deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 AWS_PAGER=""
ENDPOINT="${ENDPOINT:-http://localhost:4566}"
REGION=us-east-1 ACCOUNT=000000000000 TABLE=Books FUNCTION=books API_NAME=books-api STAGE=dev
aws() { command aws --endpoint-url "$ENDPOINT" "$@"; }

echo "--- 0. LocalStack"
until curl -sf "$ENDPOINT/_localstack/health" | grep -q '"lambda": "\(available\|running\)"'; do sleep 2; done

echo "--- 1. Пакування"
mkdir -p build && rm -f build/books.zip && (cd lambda && zip -q ../build/books.zip handler.py)

echo "--- 2. DynamoDB"
if ! aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  aws dynamodb create-table --table-name "$TABLE" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE"
fi

echo "--- 3. IAM"
aws iam get-role --role-name lambda-books-role >/dev/null 2>&1 ||
  aws iam create-role --role-name lambda-books-role \
    --assume-role-policy-document file://iam/trust-policy.json >/dev/null
ROLE_ARN="arn:aws:iam::$ACCOUNT:role/lambda-books-role"

echo "--- 4. Lambda"
if aws lambda get-function --function-name "$FUNCTION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNCTION" --zip-file fileb://build/books.zip >/dev/null
  aws lambda wait function-updated-v2 --function-name "$FUNCTION"
else
  aws lambda create-function --function-name "$FUNCTION" --runtime python3.12 \
    --handler handler.lambda_handler --zip-file fileb://build/books.zip --role "$ROLE_ARN" \
    --timeout 30 --memory-size 256 --environment "Variables={TABLE_NAME=$TABLE}" >/dev/null
fi
aws lambda wait function-active-v2 --function-name "$FUNCTION"
FUNCTION_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:$FUNCTION"

echo "--- 5. API Gateway"
for id in $(aws apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text); do
  aws apigateway delete-rest-api --rest-api-id "$id"
done
API_ID=$(aws apigateway create-rest-api --name "$API_NAME" --query id --output text)
ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --query "items[?path=='/'].id" --output text)
BOOKS_ID=$(aws apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" --path-part books --query id --output text)
BOOK_ID=$(aws apigateway create-resource --rest-api-id "$API_ID" --parent-id "$BOOKS_ID" --path-part '{id}' --query id --output text)
HEALTH_ID=$(aws apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" --path-part health --query id --output text)
URI="arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$FUNCTION_ARN/invocations"
for res in "$BOOKS_ID" "$BOOK_ID" "$HEALTH_ID"; do
  aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$res" --http-method ANY --authorization-type NONE >/dev/null
  aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$res" --http-method ANY \
    --type AWS_PROXY --integration-http-method POST --uri "$URI" >/dev/null
done

echo "--- 6. Дозвіл"
aws lambda remove-permission --function-name "$FUNCTION" --statement-id apigw-invoke >/dev/null 2>&1 || true
aws lambda add-permission --function-name "$FUNCTION" --statement-id apigw-invoke \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API_ID/*/*/*" >/dev/null

echo "--- 7. Deployment"
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$STAGE" >/dev/null
BASE_URL="$ENDPOINT/restapis/$API_ID/$STAGE/_user_request_"
echo "$BASE_URL" > build/api-url.txt
echo "Готово: $BASE_URL"
