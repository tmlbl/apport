/// Additional configuration for Apport that sits alongside a Dockerfile
/// "Frozen" image references that point to specific cached versions
images: []ImageRef,

pub const ImageRef = struct {
    repo: []const u8,
    tag: []const u8,
    id: []const u8,
};
