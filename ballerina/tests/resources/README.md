Throwaway self-signed certificate for `localhost` (CN and SAN). It protects
nothing. `listener_url_test.bal` serves and reaches a TLS listener with it, and
`listener_auth_test.bal` signs and verifies JWTs with it as a second identity
provider. Regenerate with:

    openssl req -x509 -newkey rsa:2048 -nodes -keyout localhost.key -out localhost.crt \
      -days 36500 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
