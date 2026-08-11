const validHostChallenge = 'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';
const validHostId = 'ehost-56475aa75463474c0285';
const validHostPublicKey = 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg';
const validHostPublicKeyFingerprint =
    'sha256:Vkdap1RjR0wChd9dvyvKtz2mUTWIOem3dIGy6rEHcIw';
const validBleServiceUuid = 'f6a147b7-abef-57c3-973f-e3a17c6ef0ab';

const validCommissioningEndpoint = <String, dynamic>{
  'contract_version': '1',
  'purpose': 'eidolon-ble-commissioning-endpoint-v1',
  'host_public_key': validHostPublicKey,
  'reset_epoch': 0,
  'tls_spki_fingerprint': 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8',
  'setup_session': {
    'commissioning_id': '123e4567-e89b-42d3-a456-426614174000',
    'expires_at': '2026-08-05T00:30:00Z',
  },
  'signature':
      'BaABOuhs4MSn9aYco-oKwTpnz0DA5MVIUe9Lnwfsfd83-qRhigOLL4MIWvmp-DUPQV6OqQyypxuS7iq2EkkbDA',
};
