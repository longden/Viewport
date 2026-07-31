/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * Licensed under the MIT License (facebook/idb).
 */
#pragma pack(push, 4)
typedef struct {
  unsigned int msgh_bits;
  unsigned int msgh_size;
  unsigned int msgh_remote_port;
  unsigned int msgh_local_port;
  unsigned int msgh_voucher_port;
  int msgh_id;
} MachMessageHeader;
#pragma pack(pop)
