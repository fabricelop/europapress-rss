import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/worker.mjs";

const origin = "https://ttactualidad-v2-acceso.fabricelop.workers.dev";

test("la portada conserva autenticación de la V2 original", async () => {
  const request = new Request(origin + "/");
  const env = {V2_ORIGIN: {fetch: async forwarded => {
    assert.equal(forwarded, request);
    return new Response("Acceso privado", {status: 200, headers: {"cache-control": "no-store"}});
  }}};
  const response = await worker.fetch(request, env);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), "Acceso privado");
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("el inicio de sesión mantiene origen, contraseña, cuerpo y cookie intactos", async () => {
  const request = new Request(origin + "/api/login", {
    method: "POST",
    headers: {"origin": origin, "content-type": "application/json", "x-ttv2-action": "1"},
    body: JSON.stringify({password: "solo-valor-ficticio-de-prueba"})
  });
  const env = {V2_ORIGIN: {fetch: async forwarded => {
    assert.equal(forwarded, request);
    assert.equal(new URL(forwarded.url).origin, forwarded.headers.get("origin"));
    assert.deepEqual(await forwarded.json(), {password: "solo-valor-ficticio-de-prueba"});
    return new Response(JSON.stringify({ok: true}), {
      status: 200,
      headers: {"set-cookie": "ttv2_session=prueba; Path=/; Secure; HttpOnly; SameSite=Strict"}
    });
  }}};
  const response = await worker.fetch(request, env);
  assert.equal(response.headers.get("set-cookie"),
    "ttv2_session=prueba; Path=/; Secure; HttpOnly; SameSite=Strict");
});

test("las acciones PU y R mantienen el cuerpo y la sesión autenticada", async () => {
  for (const path of ["/api/publication-count", "/api/marks"]) {
    const request = new Request(origin + path, {
      method: "POST", headers: {"cookie": "ttv2_session=prueba", "origin": origin}, body: "{}"
    });
    const response = await worker.fetch(request, {V2_ORIGIN: {fetch: async forwarded => {
      assert.equal(forwarded, request);
      assert.equal(forwarded.headers.get("cookie"), "ttv2_session=prueba");
      return new Response("{}", {status: 200});
    }}});
    assert.equal(response.status, 200);
  }
});

test("si falta el vínculo privado, falla cerrado", async () => {
  const response = await worker.fetch(new Request(origin + "/api/me"), {});
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("cache-control"), "no-store");
});
