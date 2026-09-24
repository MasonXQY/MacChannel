package evidence

import "testing"

func TestFailureExposesOnlyCategory(t *testing.T) {
	failure := &Failure{Category: InvalidSchema, Blocked: false}
	if got := failure.Error(); got != "schema" {
		t.Fatalf("Error() = %q", got)
	}
}
