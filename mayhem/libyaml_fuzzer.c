// Copyright 2016 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Original OSS-Fuzz harness for libyaml — exercises yaml_parser_parse (event API).
// Mirrors the libyaml_fuzzer target from google/oss-fuzz projects/libyaml.

#include "yaml.h"
#include <stdint.h>
#include <stdlib.h>

#ifdef NDEBUG
#undef NDEBUG
#endif

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  yaml_parser_t parser;
  yaml_event_t event;

  if (!yaml_parser_initialize(&parser))
    return 0;

  yaml_parser_set_input_string(&parser, data, size);

  while (1) {
    if (!yaml_parser_parse(&parser, &event))
      break;
    int done = (event.type == YAML_STREAM_END_EVENT);
    yaml_event_delete(&event);
    if (done)
      break;
  }

  yaml_parser_delete(&parser);
  return 0;
}
