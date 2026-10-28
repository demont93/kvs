# Protocol

## Requests

### Request Wire Format

```ebnf
request = BL , KL , OP , K , [ V ] ;

BL = u32 ; (* big-endian, 0 < BL <= 16MiB + KL *)
KL = u32 ; (* big-endian, 0 < KL <= 64KiB *)
K = { u8 } ; (* 0 < length <= 64KiB *)
V = { u8 } ; (* 0 <= length <= 16MiB *)

OP = GET | SET | DEL ;
GET = 0u8 ;
SET = 1u8 ;
DEL = 2u8 ;
```

- GET and DEL require that BL == KL.
- KL must match length(K)
- BL must match length(K) + length(V)

## Responses

### Response Wire Format

```ebnf
GET = OK , VL , Value | ( Err | NotFound ) , Zero ;
SET = ( OK | Err ) , Zero ;
DEL = ( OK | Err | NotFound ) , Zero ;

VL = u32 ; (* big-endian, <= 16 MiB, >= 0 *)
Value = { u8 } ; (* 0 <= length <= 16MiB *)

OK = 0u8 ;
NotFound = 1u8 ;

Err = InvalidRequest | Timeout | Internal ;
InvalidRequest = 2u8 ;
Timeout = 3u8 ;
Internal = 4u8 ;

Zero = 0u32 ; (* big-endian *)
```

- VL must match length(Value)

## Errors

Any protocol errors besides timeouts will be responded with InvalidRequest and a draining close.

Clients must stop writing on error response.

### Timeout

Timeout byte is sent only when operation is not applied on the following cases:

- Read Timeout
- Request Timeout

## Limits

- Max Key Size: 64KiB
- Max Value Size: 16MiB
- Max Memory (unimplemented)
- Idle connection timeout: 10s
