# Received folder navigation

User approved attempting direct Files-app navigation, then native picker fallback.
Read the actual session receiveDirectory, not a hard-coded sandbox path. Validate
it is an existing nonsymlink directory. Encode a shareddocuments URL with
URLComponents; open only after button tap. The scheme is best-effort, not an Apple
documented guarantee of folder positioning. False open completion presents
UIDocumentPickerViewController with directoryURL; selected files may be previewed
while scoped access is held. No copies/deletion/relocation or transfer changes.

Verification: red/green tests for URL path encoding, failed-open exact-folder
fallback and unavailable-folder denial. Native picker directory configuration,
build and connected-device overwrite installation. Real Files folder positioning
must be checked visually by user; successful URL dispatch alone is not proof.
