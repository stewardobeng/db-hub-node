<?php
declare(strict_types=1);

function base64url_encode(string $raw): string
{
    return rtrim(strtr(base64_encode($raw), '+/', '-_'), '=');
}

function base64url_decode(string $value): string
{
    $value = strtr($value, '-_', '+/');
    $padding = strlen($value) % 4;
    if ($padding > 0) {
        $value .= str_repeat('=', 4 - $padding);
    }
    $decoded = base64_decode($value, true);
    if ($decoded === false) {
        throw new InvalidArgumentException('Invalid base64url payload.');
    }
    return $decoded;
}

function mfa_json_response(array $payload, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=UTF-8');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

function mfa_actor_id(string $role, ?int $actorId): int
{
    return $role === 'admin' ? 0 : max(0, (int)$actorId);
}

function mfa_host_name(): string
{
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https://' : 'http://';
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    return (string)(parse_url($scheme . $host, PHP_URL_HOST) ?: 'localhost');
}

function mfa_origin(): string
{
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    $host = $_SERVER['HTTP_HOST'] ?? 'localhost';
    return $scheme . '://' . $host;
}

function mfa_user_handle(string $role, int $actorId): string
{
    return hash('sha256', $role . ':' . $actorId . ':' . APP_SECRET, true);
}

function mfa_random_code(int $digits = 6): string
{
    $digits = max(4, min(10, $digits));
    $max = (10 ** $digits) - 1;
    return str_pad((string)random_int(0, $max), $digits, '0', STR_PAD_LEFT);
}

function mfa_base32_encode(string $bytes): string
{
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $buffer = 0;
    $bitsLeft = 0;
    $output = '';
    for ($i = 0, $len = strlen($bytes); $i < $len; $i++) {
        $buffer = ($buffer << 8) | ord($bytes[$i]);
        $bitsLeft += 8;
        while ($bitsLeft >= 5) {
            $output .= $alphabet[($buffer >> ($bitsLeft - 5)) & 31];
            $bitsLeft -= 5;
        }
    }
    if ($bitsLeft > 0) {
        $output .= $alphabet[($buffer << (5 - $bitsLeft)) & 31];
    }
    return $output;
}

function mfa_base32_decode(string $secret): string
{
    $secret = strtoupper(preg_replace('/[^A-Z2-7]/', '', $secret) ?? '');
    $alphabet = array_flip(str_split('ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'));
    $buffer = 0;
    $bitsLeft = 0;
    $output = '';
    for ($i = 0, $len = strlen($secret); $i < $len; $i++) {
        $char = $secret[$i];
        if (!isset($alphabet[$char])) {
            throw new InvalidArgumentException('Invalid authenticator secret.');
        }
        $buffer = ($buffer << 5) | $alphabet[$char];
        $bitsLeft += 5;
        if ($bitsLeft >= 8) {
            $output .= chr(($buffer >> ($bitsLeft - 8)) & 255);
            $bitsLeft -= 8;
        }
    }
    return $output;
}

function mfa_generate_totp_secret(): string
{
    return mfa_base32_encode(random_bytes(20));
}

function mfa_totp_code(string $secret, ?int $slice = null): string
{
    $key = mfa_base32_decode($secret);
    $slice ??= (int)floor(time() / 30);
    $binaryTime = pack('N2', 0, $slice);
    $hash = hash_hmac('sha1', $binaryTime, $key, true);
    $offset = ord(substr($hash, -1)) & 0x0F;
    $chunk = substr($hash, $offset, 4);
    $value = unpack('N', $chunk)[1] & 0x7FFFFFFF;
    return str_pad((string)($value % 1000000), 6, '0', STR_PAD_LEFT);
}

function mfa_verify_totp(string $secret, string $code, int $window = 1): bool
{
    $code = preg_replace('/\D+/', '', $code) ?? '';
    if (strlen($code) !== 6) {
        return false;
    }
    $slice = (int)floor(time() / 30);
    for ($offset = -$window; $offset <= $window; $offset++) {
        if (hash_equals(mfa_totp_code($secret, $slice + $offset), $code)) {
            return true;
        }
    }
    return false;
}

function mfa_method_rows(PDO $db, string $role, int $actorId): array
{
    $stmt = $db->prepare("SELECT * FROM mfa_methods WHERE actor_role = ? AND actor_id = ? AND enabled = 1 ORDER BY method_type != 'passkey', id ASC");
    $stmt->execute([$role, mfa_actor_id($role, $actorId)]);
    return $stmt->fetchAll(PDO::FETCH_ASSOC);
}

function mfa_method_by_id(PDO $db, int $methodId, string $role, int $actorId): ?array
{
    $stmt = $db->prepare("SELECT * FROM mfa_methods WHERE id = ? AND actor_role = ? AND actor_id = ?");
    $stmt->execute([$methodId, $role, mfa_actor_id($role, $actorId)]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return $row ?: null;
}

function mfa_has_method_type(array $methods, string $type): bool
{
    foreach ($methods as $method) {
        if (($method['method_type'] ?? '') === $type) {
            return true;
        }
    }
    return false;
}

function mfa_passkey_rows(array $methods): array
{
    return array_values(array_filter($methods, static fn(array $method): bool => ($method['method_type'] ?? '') === 'passkey'));
}

function mfa_cbor_length(string $data, int &$offset, int $additional): int
{
    if ($additional < 24) {
        return $additional;
    }
    $size = match ($additional) {
        24 => 1,
        25 => 2,
        26 => 4,
        27 => 8,
        default => throw new UnexpectedValueException('Unsupported CBOR length encoding.'),
    };
    $segment = substr($data, $offset, $size);
    if (strlen($segment) !== $size) {
        throw new UnexpectedValueException('Truncated CBOR payload.');
    }
    $offset += $size;
    return match ($size) {
        1 => ord($segment),
        2 => unpack('n', $segment)[1],
        4 => unpack('N', $segment)[1],
        8 => (int)hexdec(bin2hex($segment)),
    };
}

function mfa_cbor_decode(string $data, int &$offset = 0): mixed
{
    if (!isset($data[$offset])) {
        throw new UnexpectedValueException('Unexpected end of CBOR payload.');
    }
    $initial = ord($data[$offset++]);
    $major = $initial >> 5;
    $additional = $initial & 31;
    return match ($major) {
        0 => mfa_cbor_length($data, $offset, $additional),
        1 => -1 - mfa_cbor_length($data, $offset, $additional),
        2 => (function () use ($data, &$offset, $additional): string {
            $length = mfa_cbor_length($data, $offset, $additional);
            $chunk = substr($data, $offset, $length);
            if (strlen($chunk) !== $length) {
                throw new UnexpectedValueException('Truncated byte string.');
            }
            $offset += $length;
            return $chunk;
        })(),
        3 => (function () use ($data, &$offset, $additional): string {
            $length = mfa_cbor_length($data, $offset, $additional);
            $chunk = substr($data, $offset, $length);
            if (strlen($chunk) !== $length) {
                throw new UnexpectedValueException('Truncated text string.');
            }
            $offset += $length;
            return $chunk;
        })(),
        4 => (function () use ($data, &$offset, $additional): array {
            $length = mfa_cbor_length($data, $offset, $additional);
            $items = [];
            for ($i = 0; $i < $length; $i++) {
                $items[] = mfa_cbor_decode($data, $offset);
            }
            return $items;
        })(),
        5 => (function () use ($data, &$offset, $additional): array {
            $length = mfa_cbor_length($data, $offset, $additional);
            $items = [];
            for ($i = 0; $i < $length; $i++) {
                $key = mfa_cbor_decode($data, $offset);
                $items[$key] = mfa_cbor_decode($data, $offset);
            }
            return $items;
        })(),
        6 => mfa_cbor_decode($data, $offset),
        7 => match ($additional) {
            20 => false,
            21 => true,
            22, 23 => null,
            default => throw new UnexpectedValueException('Unsupported CBOR simple value.'),
        },
        default => throw new UnexpectedValueException('Unsupported CBOR type.'),
    };
}

function mfa_parse_authenticator_data(string $authData, bool $expectCredentialData): array
{
    if (strlen($authData) < 37) {
        throw new UnexpectedValueException('Authenticator data is too short.');
    }
    $flags = ord($authData[32]);
    $offset = 37;
    $parsed = [
        'rpIdHash' => substr($authData, 0, 32),
        'flags' => $flags,
        'signCount' => unpack('N', substr($authData, 33, 4))[1],
        'credentialId' => '',
        'credentialPublicKey' => '',
    ];
    if ($expectCredentialData) {
        if (($flags & 0x40) !== 0x40) {
            throw new UnexpectedValueException('Attested credential data flag is missing.');
        }
        if (strlen($authData) < $offset + 18) {
            throw new UnexpectedValueException('Attested credential data is truncated.');
        }
        $offset += 16; // AAGUID
        $credentialLength = unpack('n', substr($authData, $offset, 2))[1];
        $offset += 2;
        $credentialId = substr($authData, $offset, $credentialLength);
        if (strlen($credentialId) !== $credentialLength) {
            throw new UnexpectedValueException('Credential ID is truncated.');
        }
        $offset += $credentialLength;
        $credentialKeyOffset = $offset;
        mfa_cbor_decode($authData, $offset);
        $parsed['credentialId'] = $credentialId;
        $parsed['credentialPublicKey'] = substr($authData, $credentialKeyOffset, $offset - $credentialKeyOffset);
    }
    return $parsed;
}

function mfa_der_length(int $length): string
{
    if ($length < 128) {
        return chr($length);
    }
    $encoded = ltrim(pack('N', $length), "\x00");
    return chr(0x80 | strlen($encoded)) . $encoded;
}

function mfa_der_encode(int $tag, string $value): string
{
    return chr($tag) . mfa_der_length(strlen($value)) . $value;
}

function mfa_der_sequence(array $parts): string
{
    return mfa_der_encode(0x30, implode('', $parts));
}

function mfa_der_integer(string $value): string
{
    $value = ltrim($value, "\x00");
    if ($value === '' || (ord($value[0]) & 0x80) !== 0) {
        $value = "\x00" . $value;
    }
    return mfa_der_encode(0x02, $value);
}

function mfa_der_bit_string(string $value): string
{
    return mfa_der_encode(0x03, "\x00" . $value);
}

function mfa_der_null(): string
{
    return "\x05\x00";
}

function mfa_der_oid(string $oid): string
{
    $parts = array_map('intval', explode('.', $oid));
    if (count($parts) < 2) {
        throw new InvalidArgumentException('Invalid object identifier.');
    }
    $first = (40 * $parts[0]) + $parts[1];
    $encoded = chr($first);
    for ($i = 2, $count = count($parts); $i < $count; $i++) {
        $value = $parts[$i];
        $segment = '';
        do {
            $segment = chr($value & 0x7F) . $segment;
            $value >>= 7;
        } while ($value > 0);
        $last = strlen($segment) - 1;
        for ($j = 0; $j < $last; $j++) {
            $segment[$j] = chr(ord($segment[$j]) | 0x80);
        }
        $encoded .= $segment;
    }
    return mfa_der_encode(0x06, $encoded);
}

function mfa_cose_to_pem(string $coseKey): string
{
    $offset = 0;
    $key = mfa_cbor_decode($coseKey, $offset);
    if (!is_array($key) || !isset($key[1])) {
        throw new UnexpectedValueException('Unsupported passkey public key.');
    }

    if ((int)$key[1] === 2) {
        $curveOid = match ((int)($key[-1] ?? 0)) {
            1 => '1.2.840.10045.3.1.7',
            default => throw new UnexpectedValueException('Unsupported EC curve.'),
        };
        $x = (string)($key[-2] ?? '');
        $y = (string)($key[-3] ?? '');
        if ($x === '' || $y === '') {
            throw new UnexpectedValueException('Incomplete EC public key.');
        }
        $point = "\x04" . $x . $y;
        $der = mfa_der_sequence([
            mfa_der_sequence([
                mfa_der_oid('1.2.840.10045.2.1'),
                mfa_der_oid($curveOid),
            ]),
            mfa_der_bit_string($point),
        ]);
    } elseif ((int)$key[1] === 3) {
        $modulus = (string)($key[-1] ?? '');
        $exponent = (string)($key[-2] ?? '');
        if ($modulus === '' || $exponent === '') {
            throw new UnexpectedValueException('Incomplete RSA public key.');
        }
        $rsaKey = mfa_der_sequence([
            mfa_der_integer($modulus),
            mfa_der_integer($exponent),
        ]);
        $der = mfa_der_sequence([
            mfa_der_sequence([
                mfa_der_oid('1.2.840.113549.1.1.1'),
                mfa_der_null(),
            ]),
            mfa_der_bit_string($rsaKey),
        ]);
    } else {
        throw new UnexpectedValueException('Unsupported passkey key type.');
    }

    return "-----BEGIN PUBLIC KEY-----\n"
        . chunk_split(base64_encode($der), 64, "\n")
        . "-----END PUBLIC KEY-----\n";
}

function mfa_parse_client_data(string $clientDataJson, string $expectedType, string $expectedChallenge): array
{
    $decoded = json_decode($clientDataJson, true);
    if (!is_array($decoded)) {
        throw new UnexpectedValueException('Invalid client data payload.');
    }
    if (($decoded['type'] ?? '') !== $expectedType) {
        throw new UnexpectedValueException('Unexpected WebAuthn operation.');
    }
    if (($decoded['challenge'] ?? '') !== base64url_encode($expectedChallenge)) {
        throw new UnexpectedValueException('WebAuthn challenge mismatch.');
    }
    if (($decoded['origin'] ?? '') !== mfa_origin()) {
        throw new UnexpectedValueException('WebAuthn origin mismatch.');
    }
    return $decoded;
}

function mfa_register_passkey_payload(array $payload, string $expectedChallenge): array
{
    $clientDataJson = base64url_decode((string)($payload['response']['clientDataJSON'] ?? ''));
    mfa_parse_client_data($clientDataJson, 'webauthn.create', $expectedChallenge);

    $attestationObject = base64url_decode((string)($payload['response']['attestationObject'] ?? ''));
    $offset = 0;
    $decoded = mfa_cbor_decode($attestationObject, $offset);
    if (!is_array($decoded) || !isset($decoded['authData'])) {
        throw new UnexpectedValueException('Invalid attestation payload.');
    }
    $authData = (string)$decoded['authData'];
    $parsed = mfa_parse_authenticator_data($authData, true);
    if (!hash_equals(hash('sha256', mfa_host_name(), true), $parsed['rpIdHash'])) {
        throw new UnexpectedValueException('Passkey rpId mismatch.');
    }
    if (($parsed['flags'] & 0x01) !== 0x01) {
        throw new UnexpectedValueException('Passkey user presence was not verified.');
    }
    $credentialId = base64url_encode((string)$parsed['credentialId']);
    return [
        'credential_id' => $credentialId,
        'credential_public_key' => mfa_cose_to_pem((string)$parsed['credentialPublicKey']),
        'sign_count' => (int)$parsed['signCount'],
        'transports' => json_encode($payload['response']['transports'] ?? []),
        'label' => trim((string)($payload['label'] ?? 'Passkey')),
    ];
}

function mfa_verify_passkey_assertion(array $payload, string $expectedChallenge, array $method): int
{
    $clientDataJson = base64url_decode((string)($payload['response']['clientDataJSON'] ?? ''));
    mfa_parse_client_data($clientDataJson, 'webauthn.get', $expectedChallenge);

    $authenticatorData = base64url_decode((string)($payload['response']['authenticatorData'] ?? ''));
    $signature = base64url_decode((string)($payload['response']['signature'] ?? ''));
    $credentialId = (string)($payload['id'] ?? '');
    if (!hash_equals((string)$method['credential_id'], $credentialId)) {
        throw new UnexpectedValueException('Passkey credential mismatch.');
    }
    $parsed = mfa_parse_authenticator_data($authenticatorData, false);
    if (!hash_equals(hash('sha256', mfa_host_name(), true), $parsed['rpIdHash'])) {
        throw new UnexpectedValueException('Passkey rpId mismatch.');
    }
    if (($parsed['flags'] & 0x01) !== 0x01) {
        throw new UnexpectedValueException('Passkey user presence was not verified.');
    }
    $signedData = $authenticatorData . hash('sha256', $clientDataJson, true);
    $verified = openssl_verify($signedData, $signature, (string)$method['credential_public_key'], OPENSSL_ALGO_SHA256);
    if ($verified !== 1) {
        throw new UnexpectedValueException('Passkey signature verification failed.');
    }
    return max((int)($method['sign_count'] ?? 0), (int)$parsed['signCount']);
}
