// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#ifndef JAVASCRIPT_CORE_SUPPORT_H
#define JAVASCRIPT_CORE_SUPPORT_H

#include <JavaScriptCore/JSContextRef.h>
#include <stdbool.h>

typedef bool (*UASJavaScriptShouldTerminateCallback)(JSContextRef context,
                                                     void *callback_context);

void UASSetJavaScriptExecutionTimeLimit(
    JSGlobalContextRef context, double limit,
    UASJavaScriptShouldTerminateCallback callback, void *callback_context);
void UASClearJavaScriptExecutionTimeLimit(JSGlobalContextRef context);

#endif
