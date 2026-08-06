const validHostChallenge = 'ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8';

const validHostProof = <String, dynamic>{
  'contract_version': '1',
  'purpose': 'eidolon-local-api-host-proof-v1',
  'host_id': 'ehost-56475aa75463474c0285',
  'challenge': validHostChallenge,
  'signature':
      'rF3KrfUegMPsqmrjfbBpDy-2xhay3RdqRFslSH_oEDepS3vabevWP9haxt5w1xdW5QeSVKek2HCMwiaasj8yCQ',
};

const validCommissioningEndpoint = <String, dynamic>{
  'contract_version': '1',
  'purpose': 'eidolon-ble-commissioning-endpoint-v1',
  'host_id': 'ehost-56475aa75463474c0285',
  'host_public_key': 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg',
  'host_public_key_fingerprint':
      'sha256:Vkdap1RjR0wChd9dvyvKtz2mUTWIOem3dIGy6rEHcIw',
  'reset_epoch': 0,
  'ble_service_uuid': 'f6a147b7-abef-57c3-973f-e3a17c6ef0ab',
  'tls_spki_fingerprint': 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8',
  'development_setup': {
    'commissioning_id': '123e4567-e89b-42d3-a456-426614174000',
    'expires_at': '2026-08-05T00:30:00Z',
  },
  'signature':
      '-x-cYgUK-kyltf8i63aIqxdtelif_izfcTB3bMGthFL3aCr01f7xO0Z72EWyUb36erP-gcCGATkeMV0BmJSAAg',
};
