# Troubleshooting Runbook: SSL / TLS Certificate Expiration

## 1. Alert Overview
- **Associated Alert:** `BlackboxSslCertExpiring`
- **PromQL Trigger:** `probe_ssl_earliest_cert_expiry - time() < 86400 * 14`
- **Severity:** Warning (< 14 days) / Critical (< 7 days)
- **SLO Impact:** Risk of impending TLS termination outages and customer connection errors.

---

## 2. Immediate Triage & Diagnostics
1. **Query Certificate Expiry Date via OpenSSL:**
   ```bash
   TARGET="example.com:443"
   echo | openssl s_client -servername ${TARGET%%:*} -connect ${TARGET} 2>/dev/null | openssl x509 -noout -dates -subject -issuer
   ```
2. **Query Prometheus SSL Expiry Value:**
   ```bash
   curl -sG http://127.0.0.1:9091/api/v1/query --data-urlencode 'query=(probe_ssl_earliest_cert_expiry - time()) / 86400' | jq .
   ```

---

## 3. Resolution Procedures
1. **Automated Certbot Renewal (if Let's Encrypt managed):**
   ```bash
   sudo certbot renew --dry-run
   sudo certbot renew --quiet
   ```
2. **Reload Ingress / Reverse Proxy:**
   ```bash
   sudo systemctl reload nginx || docker exec lab-proxy nginx -s reload
   ```
3. **Verify Re-deployed Certificate Chain:**
   ```bash
   curl -Iv https://${TARGET}
   ```

---

## 4. Recovery Verification
- Verify that `probe_ssl_earliest_cert_expiry - time() > 86400 * 30`.
