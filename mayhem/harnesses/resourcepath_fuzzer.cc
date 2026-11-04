// ResourcePath fuzz target. Upstream's Firestore/fuzzing/resourcepath_fuzzer.cc only calls
// ResourcePath::FromString and discards the result (31 edges, saturated in seconds). This harness feeds the
// same bytes through the rest of the path API: canonical-string round trip, segment arithmetic, comparison
// (incl. the "__id<N>__" numeric-segment ordering), hashing and the DocumentKey constructors.
#include <cstddef>
#include <cstdint>
#include <string>

#include "Firestore/core/src/model/document_key.h"
#include "Firestore/core/src/model/resource_path.h"
#include "Firestore/core/src/util/comparison.h"

using firebase::firestore::model::DocumentKey;
using firebase::firestore::model::ResourcePath;
namespace util = firebase::firestore::util;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  std::string str{reinterpret_cast<const char*>(data), size};

  try {
    ResourcePath rp = ResourcePath::FromString(str);

    // Canonical form has no empty segments, so it must parse back to the same path.
    std::string canonical = rp.CanonicalString();
    ResourcePath again = ResourcePath::FromString(canonical);
    if (!(again == rp) || again.CanonicalString() != canonical) __builtin_trap();

    // Split the input in two at a byte-derived point and relate the halves.
    size_t cut = size == 0 ? 0 : data[0] % (size + 1);
    ResourcePath left = ResourcePath::FromString(str.substr(0, cut));
    ResourcePath right = ResourcePath::FromString(str.substr(cut));

    ResourcePath joined = left.Append(right);
    (void)joined.CanonicalString();
    (void)left.IsPrefixOf(joined);
    (void)left.IsImmediateParentOf(joined);
    (void)joined.Hash();

    if (!rp.empty()) {
      size_t n = data[size - 1] % (rp.size() + 1);
      ResourcePath rest = rp.PopFirst(n);
      ResourcePath parent = rp.PopLast();
      (void)rest.CanonicalString();
      (void)parent.IsImmediateParentOf(rp);
      (void)parent.Append(rp.last_segment());
      (void)rp.first_segment();
      (void)rp[n % rp.size()];
    }

    // Numeric-id segments ("__id12__") compare via std::stol; garbage between the markers throws.
    util::ComparisonResult cmp = left.CompareTo(right);
    util::ComparisonResult rev = right.CompareTo(left);
    (void)cmp;
    (void)rev;
    (void)rp.CompareTo(rp);

    (void)DocumentKey::IsDocumentKey(rp);
    DocumentKey key = DocumentKey::FromPathString(str);
    (void)key.ToString();
    (void)key.GetCollectionGroup();
    (void)key.HasCollectionGroup(str);
    (void)key.Hash();
  } catch (...) {
    // Ignore caught errors and assertions, as upstream's harness does.
  }

  try {
    DocumentKey name = DocumentKey::FromName(str);
    (void)name.ToString();
  } catch (...) {
  }

  return 0;
}
