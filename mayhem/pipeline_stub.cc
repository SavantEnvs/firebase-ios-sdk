// api::Pipeline::execute() (the network entry point of the pipeline API) calls this member of
// api::Firestore, whose real definition drags in the whole client stack (gRPC, datastore, async
// queue). No fuzz target reaches execute(); the symbol only has to exist so the serializer's
// pipeline decoders link. It aborts so an unexpected call can never go unnoticed.
#include <cstdlib>
#include <functional>

#include "Firestore/core/src/api/firestore.h"
#include "Firestore/core/src/api/pipeline.h"

namespace firebase {
namespace firestore {
namespace api {

void Firestore::RunPipeline(
    const api::Pipeline&,
    std::function<void(util::StatusOr<api::PipelineSnapshot>)>) {
  std::abort();
}

}  // namespace api
}  // namespace firestore
}  // namespace firebase
