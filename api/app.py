import os
import psycopg2
import redis
from flask import Flask, jsonify

app = Flask(__name__)
r = redis.Redis(host="redis", port=6379, decode_responses=True)

def get_db_connection():
    return psycopg2.connect(
        host="postgres",
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        dbname=os.environ["POSTGRES_DB"],
    )

@app.route("/health")
def health():
    return jsonify(status="ok")

@app.route("/")
def index():
    count = r.incr("visits")
    return jsonify(message="Merhaba capstone!", visits=count)

@app.route("/db-check")
def db_check():
    conn = None
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT 1;")
        result = cur.fetchone()
        cur.close()
        return jsonify(db=result[0])
    finally:
        if conn is not None:
            conn.close()
