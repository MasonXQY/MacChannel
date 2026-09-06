package evidence

type Category string

const (
	InvalidSchema    Category = "schema"
	InvalidPolicy    Category = "policy"
	InvalidSignature Category = "signature"
	InvalidInventory Category = "inventory"
	InvalidReceipt   Category = "receipt"
	InvalidTime      Category = "time"
	UnsafeInput      Category = "unsafe-input"
	UnavailableInput Category = "unavailable-input"
	InvalidUsage     Category = "usage"
)

type Failure struct {
	Category Category
	Blocked  bool
}

func (e *Failure) Error() string { return string(e.Category) }

type Bundle struct {
	Manifest  []byte
	Signature []byte
	Artifacts map[string][]byte
}
