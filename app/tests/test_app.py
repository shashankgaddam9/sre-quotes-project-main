import fakeredis
import pytest

import main


@pytest.fixture
def client():
    main.set_redis_client(fakeredis.FakeRedis(decode_responses=True))
    main.app.config["TESTING"] = True
    with main.app.test_client() as c:
        yield c


def test_healthz(client):
    assert client.get("/healthz").status_code == 200


def test_readyz_when_redis_ok(client):
    assert client.get("/readyz").status_code == 200


def test_add_and_list_quote(client):
    resp = client.post("/api/quotes", json={"text": "Hope is not a strategy", "author": "SRE book"})
    assert resp.status_code == 201
    data = client.get("/api/quotes").get_json()
    assert data["count"] == 1
    assert data["quotes"][0]["text"] == "Hope is not a strategy"


def test_add_quote_requires_text(client):
    assert client.post("/api/quotes", json={}).status_code == 400


def test_random_quote_empty(client):
    assert client.get("/api/quotes/random").status_code == 404


def test_delete_quote(client):
    qid = client.post("/api/quotes", json={"text": "x"}).get_json()["id"]
    assert client.delete(f"/api/quotes/{qid}").status_code == 204
    assert client.delete(f"/api/quotes/{qid}").status_code == 404


def test_metrics_exposed(client):
    client.get("/healthz")
    body = client.get("/metrics").get_data(as_text=True)
    assert "http_requests_total" in body
    assert "http_request_duration_seconds" in body


def test_home_page(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"<title>Quotes</title>" in resp.data


def test_simulate_error(client):
    resp = client.post("/api/simulate-error")
    assert resp.status_code == 500
    assert resp.get_json()["request_id"] == resp.headers["X-Request-ID"]


def test_request_id_header(client):
    resp = client.get("/healthz", headers={"X-Request-ID": "abc123"})
    assert resp.headers["X-Request-ID"] == "abc123"
