// Serializer fuzz target. Upstream's Firestore/fuzzing/serializer_fuzzer.cc calls
// Serializer::DecodeFieldValue, which no longer exists, so the same bytes are fed to the
// decoders that do (Value parse, Document, Write -> Mutation, ListenResponse -> WatchChange).
#include <cstddef>
#include <cstdint>

#include "Firestore/Protos/nanopb/google/firestore/v1/document.nanopb.h"
#include "Firestore/Protos/nanopb/google/firestore/v1/firestore.nanopb.h"
#include "Firestore/core/src/model/database_id.h"
#include "Firestore/core/src/model/mutable_document.h"
#include "Firestore/core/src/model/mutation.h"
#include "Firestore/core/src/nanopb/message.h"
#include "Firestore/core/src/nanopb/reader.h"
#include "Firestore/core/src/remote/serializer.h"
#include "Firestore/core/src/remote/watch_change.h"

using firebase::firestore::google_firestore_v1_BatchGetDocumentsResponse;
using firebase::firestore::google_firestore_v1_ListenResponse;
using firebase::firestore::google_firestore_v1_Value;
using firebase::firestore::google_firestore_v1_Write;
using firebase::firestore::model::DatabaseId;
using firebase::firestore::nanopb::Message;
using firebase::firestore::nanopb::StringReader;
using firebase::firestore::remote::Serializer;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  Serializer serializer{DatabaseId{"project", DatabaseId::kDefault}};

  try {
    StringReader reader{data, size};
    auto message = Message<google_firestore_v1_Value>::TryParse(&reader);
  } catch (...) {
  }

  try {
    StringReader reader{data, size};
    auto message = Message<google_firestore_v1_BatchGetDocumentsResponse>::TryParse(&reader);
    if (reader.ok()) {
      serializer.DecodeMaybeDocument(reader.context(), *message);
    }
  } catch (...) {
  }

  try {
    StringReader reader{data, size};
    auto message = Message<google_firestore_v1_Write>::TryParse(&reader);
    if (reader.ok()) {
      serializer.DecodeMutation(reader.context(), *message);
    }
  } catch (...) {
  }

  try {
    StringReader reader{data, size};
    auto message = Message<google_firestore_v1_ListenResponse>::TryParse(&reader);
    if (reader.ok()) {
      serializer.DecodeWatchChange(reader.context(), *message);
    }
  } catch (...) {
  }
  return 0;
}
