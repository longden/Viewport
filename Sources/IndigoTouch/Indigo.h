/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * Licensed under the MIT License (facebook/idb PrivateHeaders/SimulatorApp/Indigo.h).
 */
#import "Mach.h"

#pragma pack(push, 4)
typedef struct {
  double field1;
  double field2;
  double field3;
  double field4;
} IndigoQuad;

typedef struct {
  unsigned int field1;
  unsigned int field2;
  unsigned int field3;
  double xRatio;
  double yRatio;
  double field6;
  double field7;
  double field8;
  unsigned int field9;
  unsigned int field10;
  unsigned int field11;
  unsigned int field12;
  unsigned int field13;
  double field14;
  double field15;
  double field16;
  double field17;
  double field18;
} IndigoTouch;

typedef struct {
  unsigned int field1;
  double field2;
  double field3;
  double field4;
  unsigned int field5;
} IndigoWheel;

typedef struct {
  unsigned int eventSource;
  unsigned int eventType;
  unsigned int eventTarget;
  unsigned int keyCode;
  unsigned int field5;
} IndigoButton;

#define ButtonEventTypeDown 0x1
#define ButtonEventTypeUp 0x2

#define ButtonEventSourceHomeButton 0x0
#define ButtonEventSourceLock 0x1
#define ButtonEventTargetHardware 0x33

typedef struct {
  unsigned int field1;
  unsigned char field2[40];
} IndigoAccelerometer;

typedef struct {
  unsigned int field1;
  double field2;
  unsigned int field3;
  double field4;
} IndigoForce;

typedef struct {
  IndigoQuad dpad;
  IndigoQuad face;
  IndigoQuad shoulder;
  IndigoQuad joystick;
} IndigoGameController;

typedef union {
  IndigoTouch touch;
  IndigoWheel wheel;
  IndigoButton button;
  IndigoAccelerometer accelerometer;
  IndigoForce force;
  IndigoGameController gameController;
} IndigoEvent;

typedef struct {
  unsigned int field1;
  unsigned long long timestamp;
  unsigned int field3;
  IndigoEvent event;
} IndigoPayload;

typedef struct {
  MachMessageHeader header;
  unsigned int innerSize;
  unsigned char eventType;
  IndigoPayload payload;
} IndigoMessage;

#define IndigoEventTypeTouch 2
#pragma pack(pop)
