package netreset

import "testing"

func TestRegisterRunUnregister(t *testing.T) {
	var a, b int
	unA := Register(func() { a++ })
	unB := Register(func() { b++ })
	Run()
	unA()
	Run()
	unB()
	Run()
	if a != 1 || b != 2 {
		t.Fatalf("a=%d b=%d, want 1 and 2", a, b)
	}
}
