Throwaway self-signed certificate for `localhost` (CN and SAN), used only by
`listener_url_test.bal` to serve and reach a TLS listener in the tests. It
protects nothing. Regenerate with:

    openssl req -x509 -newkey rsa:2048 -nodes -keyout localhost.key -out localhost.crt \
      -days 36500 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
