// Known-answer tests for the code paths the mayhem fuzz targets reach (field/resource paths,
// leveldb keys, protobuf Value decoding), run alongside upstream's own unit tests by test.sh.
#include <cstdint>
#include <string>

#include "Firestore/Protos/nanopb/google/firestore/v1/document.nanopb.h"
#include "Firestore/core/src/local/leveldb_key.h"
#include "Firestore/core/src/model/document_key.h"
#include "Firestore/core/src/model/field_path.h"
#include "Firestore/core/src/model/resource_path.h"
#include "Firestore/core/src/nanopb/message.h"
#include "Firestore/core/src/nanopb/reader.h"
#include "Firestore/core/src/util/statusor.h"
#include "gtest/gtest.h"

namespace firebase {
namespace firestore {
namespace {

using local::LevelDbRemoteDocumentKey;
using model::DocumentKey;
using model::FieldPath;
using model::ResourcePath;

TEST(MayhemOracle, FieldPathServerFormatSplitsOnDots) {
  auto path = FieldPath::FromServerFormat("foo.bar.baz");
  ASSERT_TRUE(path.ok());
  EXPECT_EQ(3u, path.ValueOrDie().size());
  EXPECT_EQ("foo", path.ValueOrDie().first_segment());
  EXPECT_EQ("baz", path.ValueOrDie().last_segment());
  EXPECT_EQ("foo.bar.baz", path.ValueOrDie().CanonicalString());
}

TEST(MayhemOracle, FieldPathServerFormatBackticksProtectDots) {
  auto path = FieldPath::FromServerFormat("a.`b.c`.d");
  ASSERT_TRUE(path.ok());
  ASSERT_EQ(3u, path.ValueOrDie().size());
  EXPECT_EQ("b.c", path.ValueOrDie()[1]);
  EXPECT_EQ("a.`b.c`.d", path.ValueOrDie().CanonicalString());
}

TEST(MayhemOracle, FieldPathServerFormatRejectsMalformedPaths) {
  EXPECT_FALSE(FieldPath::FromServerFormat("a..b").ok());
  EXPECT_FALSE(FieldPath::FromServerFormat(".a").ok());
  EXPECT_FALSE(FieldPath::FromServerFormat("a.").ok());
  EXPECT_FALSE(FieldPath::FromServerFormat("a.`b").ok());
  EXPECT_FALSE(FieldPath::FromServerFormat("a\\").ok());
}

TEST(MayhemOracle, ResourcePathFromString) {
  ResourcePath path = ResourcePath::FromString("projects/p/databases/d");
  ASSERT_EQ(4u, path.size());
  EXPECT_EQ("projects", path[0]);
  EXPECT_EQ("d", path.last_segment());
  EXPECT_EQ("projects/p/databases/d", path.CanonicalString());
}

TEST(MayhemOracle, LevelDbRemoteDocumentKeyRoundTrips) {
  DocumentKey key = DocumentKey::FromPathString("rooms/eros/messages/1");
  std::string encoded = LevelDbRemoteDocumentKey::Key(key);
  LevelDbRemoteDocumentKey decoded;
  ASSERT_TRUE(decoded.Decode(encoded));
  EXPECT_EQ("rooms/eros/messages/1", decoded.document_key().path().CanonicalString());
  EXPECT_EQ(0, encoded.compare(0, LevelDbRemoteDocumentKey::KeyPrefix().size(),
                               LevelDbRemoteDocumentKey::KeyPrefix()));
}

TEST(MayhemOracle, LevelDbRemoteDocumentKeyRejectsGarbage) {
  LevelDbRemoteDocumentKey decoded;
  EXPECT_FALSE(decoded.Decode("not a key"));
  EXPECT_FALSE(decoded.Decode(""));
}

TEST(MayhemOracle, NanopbValueDecodesBoolean) {
  const uint8_t bytes[] = {0x08, 0x01};
  nanopb::StringReader reader{bytes, sizeof(bytes)};
  auto message = nanopb::Message<google_firestore_v1_Value>::TryParse(&reader);
  ASSERT_TRUE(reader.ok());
  EXPECT_EQ(google_firestore_v1_Value_boolean_value_tag, message->which_value_type);
  EXPECT_TRUE(message->boolean_value);
}

TEST(MayhemOracle, NanopbValueDecodesInteger) {
  const uint8_t bytes[] = {0x10, 0x2a};
  nanopb::StringReader reader{bytes, sizeof(bytes)};
  auto message = nanopb::Message<google_firestore_v1_Value>::TryParse(&reader);
  ASSERT_TRUE(reader.ok());
  EXPECT_EQ(google_firestore_v1_Value_integer_value_tag, message->which_value_type);
  EXPECT_EQ(42, message->integer_value);
}

TEST(MayhemOracle, NanopbValueDecodesString) {
  const uint8_t bytes[] = {0x8a, 0x01, 0x03, 'a', 'b', 'c'};
  nanopb::StringReader reader{bytes, sizeof(bytes)};
  auto message = nanopb::Message<google_firestore_v1_Value>::TryParse(&reader);
  ASSERT_TRUE(reader.ok());
  ASSERT_EQ(google_firestore_v1_Value_string_value_tag, message->which_value_type);
  EXPECT_EQ(3u, message->string_value->size);
  EXPECT_EQ("abc", std::string(reinterpret_cast<const char*>(message->string_value->bytes), 3));
}

TEST(MayhemOracle, NanopbValueRejectsTruncatedInput) {
  const uint8_t bytes[] = {0x8a, 0x01, 0x09, 'a'};
  nanopb::StringReader reader{bytes, sizeof(bytes)};
  auto message = nanopb::Message<google_firestore_v1_Value>::TryParse(&reader);
  EXPECT_FALSE(reader.ok());
}

}  // namespace
}  // namespace firestore
}  // namespace firebase
