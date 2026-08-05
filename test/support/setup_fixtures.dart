import 'dart:convert';

/// Fixed cross-language vector produced with Admin's canonical JSON signer
/// from the test-only Ed25519 seed bytes 0..31.
const validDevDescriptor = <String, dynamic>{
  'contract_version': '1',
  'host_id': 'ehost-56475aa75463474c0285',
  'host_public_key': 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg',
  'host_public_key_fingerprint':
      'sha256:Vkdap1RjR0wChd9dvyvKtz2mUTWIOem3dIGy6rEHcIw',
  'ble_service_uuid': '179e2e95-b1ee-5aa5-8dcf-7519b6c7ac52',
  'mode': 'development',
  'commissioning_id': '123e4567-e89b-42d3-a456-426614174000',
  'commissioning_secret': 'test-commissioning-secret-0123456789abcdef',
  'issued_at': '2026-08-05T00:00:00Z',
  'expires_at': '2026-08-05T00:30:00Z',
  'signature':
      'aP5woSr_r_Tv5H9RZmdS4dgJe3g-G6Tz2BWpDBC_8grBbA0kQ_u4CFoIFEPqZsQ8EXlQNGd5Tof-t915gwqtBQ',
};

const matchingHostOverview = <String, dynamic>{
  'contract_version': '1',
  'status': 'running',
  'mode': 'development',
  'descriptor': {
    'contract_version': '1',
    'host_id': 'ehost-56475aa75463474c0285',
    'host_public_key': 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg',
    'host_public_key_fingerprint':
        'sha256:Vkdap1RjR0wChd9dvyvKtz2mUTWIOem3dIGy6rEHcIw',
    'ble_service_uuid': '179e2e95-b1ee-5aa5-8dcf-7519b6c7ac52',
  },
  'state': {
    'reset_epoch': 0,
    'claim_state': 'unclaimed',
    'network_state': 'unconfigured',
    'workspace_state': 'absent',
    'recovery_state': 'normal',
    'updated_at': '2026-08-05T00:00:00Z',
  },
};

String get validDevDescriptorJson => jsonEncode(validDevDescriptor);

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
  'reset_epoch': 0,
  'ble_service_uuid': '179e2e95-b1ee-5aa5-8dcf-7519b6c7ac52',
  'tls_spki_fingerprint': 'sha256:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8',
  'signature':
      'mYDAL32FkJnAQZI-eu9b98641hT7CzeOOoAUAdKNm7rIIvKrP_5CX2_7iu6JqFIPiTkAFuuiD-u-ffTInT-mCg',
};
