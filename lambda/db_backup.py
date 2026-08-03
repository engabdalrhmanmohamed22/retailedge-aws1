"""
Nightly logical backup: mysqldump -> gzip -> upload to S3 under db-dumps/.
Triggered by EventBridge (see data.tf: aws_cloudwatch_event_rule.nightly_backup).
Runs inside the private app subnet, reaching RDS over the VPC and S3 via the
free Gateway VPC Endpoint (no NAT hop, no extra cost).
"""
import os
import subprocess
import gzip
import shutil
import datetime
import json
import boto3

secrets = boto3.client("secretsmanager")
s3 = boto3.client("s3")


def handler(event, context):
    db_password = secrets.get_secret_value(SecretId=os.environ["SECRET_ARN"])["SecretString"]
    dump_path = "/tmp/dump.sql"
    gz_path = "/tmp/dump.sql.gz"

    subprocess.run(
        [
            "mysqldump",
            "-h", os.environ["DB_HOST"],
            "-u", os.environ["DB_USER"],
            f"-p{db_password}",
            os.environ["DB_NAME"],
        ],
        stdout=open(dump_path, "wb"),
        check=True,
    )

    with open(dump_path, "rb") as f_in, gzip.open(gz_path, "wb") as f_out:
        shutil.copyfileobj(f_in, f_out)

    ts = datetime.datetime.utcnow().strftime("%Y-%m-%d_%H-%M-%S")
    key = f"db-dumps/{os.environ['DB_NAME']}_{ts}.sql.gz"
    s3.upload_file(gz_path, os.environ["BUCKET_NAME"], key)

    return {"statusCode": 200, "body": json.dumps({"backup_key": key})}
