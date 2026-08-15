// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include "JavaScriptCoreSupport.h"

extern void JSContextGroupSetExecutionTimeLimit(
    JSContextGroupRef group, double limit,
    UASJavaScriptShouldTerminateCallback callback, void *callback_context);
extern void JSContextGroupClearExecutionTimeLimit(JSContextGroupRef group);

void UASSetJavaScriptExecutionTimeLimit(
    JSGlobalContextRef context, double limit,
    UASJavaScriptShouldTerminateCallback callback, void *callback_context) {
  JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(context), limit, callback,
                                      callback_context);
}

void UASClearJavaScriptExecutionTimeLimit(JSGlobalContextRef context) {
  JSContextGroupClearExecutionTimeLimit(JSContextGetGroup(context));
}
