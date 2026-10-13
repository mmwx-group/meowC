package snell

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"testing"
)

// The expected values in this file were produced by running the same
// transcript and the same write script through the reference implementation
// (github.com/sagernet/sing-snell, snellv6). They pin the profile derivation,
// the padding generators, the salt block, the mixing and the complete output
// of the three record writers to the reference, byte for byte. The pre-shared
// keys are chosen so that every padding generator, mixing mode, chunk policy
// and write policy occurs at least once.

type v6GoldenCase struct {
	psk         string
	profile     string // SHA-256 of the profile transcript
	shapedLen   int    // length of the default-mode write script output
	shapedWire  string // SHA-256 of the default-mode write script output
	unshapedSum string // SHA-256 of the unshaped-mode write script output
}

const (
	v6GoldenUnshapedLen = 342789
	v6GoldenRawLen      = 342277
	v6GoldenRawSum      = "e71073acaa190a9f20aa6dc4fbd4705f5fd53359fe48e66c30e3e9287cc70ba1"
)

var v6GoldenCases = []v6GoldenCase{
	{"snell-lab-psk-0123456789abcdef", "cc91ee9129d29305fdf45b4035041242830967c8bd108126ae6b9869b5d77345", 357791, "baee15cf97f10931ac9da455bd163abf507916e6e24f5295c8c9dac2092ef86c", "9a8532edbb943c639288d036a821f02f9fa9a74774ff2a81a3ce481d7c20a93f"},
	{"password", "3993117c978af51bab880854f88d045be7fd8f832c4ed19198c7c992e120b2f6", 354762, "a1af3bde488275ae6bd83dc7f1400aab374e2a608b957b2cc6cfd5cd23033e59", "0bda02bae50e98561f5dc5880cf80825425c8b207bad6b90305b2477adbcc8bc"},
	{"a", "8e2cab81f9f6d60f3e3065d9a9c257b9331d3ca5daddd7c86f19360421499338", 356890, "111633002288e09f9633824de09bf99d4da406b688cead6c6d123ca291a614bf", "c2a8ee1007d0faa950c1db7ac0563945509d10e50a32733b4b652bcf5e1182a3"},
	{"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "6cb30dc06793a10f5a8e616723e7db4655b929af74701f8b6e0f622f8f8d4f46", 361397, "d33fb0b86d5740b750501f9ad553e4d24b314643d25e1d6a52c51394aa4bfc97", "70b1a66b0a3398d3be5e518a627fafb4c20a9af104d7c6ba48e27f1a72cf2084"},
	{"psk-1", "f860243437eda5990ad1c7965ad823669641c380ee567d72db173d5b62d8f8f7", 357517, "cba03599428dbcc93ffcc177049a42dc0675dda342a133b1a3983468c49e7b20", "b873fba5fad9883aff8cab2340ee9ba49d6883a5126c3e96c617b19a0c48b1b6"},
	{"psk-2", "fa4b6db5a4efce873a28a73f504c6a9a30fdb1a2e6b78d5cccbb99522545d6b4", 353417, "ba628c02e9881262f7790e8c9c63e00ec3c37585f81eaeeda120f82bdb34ed88", "e547555e41e14cc6dd69f873fc83ceb630da9fd5d20394d9cb019034f7fd8e60"},
	{"psk-3", "9bf247b63f5de4a9ca8149f821d4c18452754a8549870428b2bb45664f548344", 354404, "b1408c4b0b53d253aafca7005171e9f39ac06695d54f18b1934b17ee33dc0f46", "63d70d4c439847be89f581e2bafdf10505fe2056d60f35cd0370f61c17da2be3"},
	{"psk-4", "42592c2ab41fe5d149a1a043a58a90fc6171f22cb8985753f590980d406f6e66", 352898, "cca3448f80848e4066460c31e4768ed7d290ac75dc9bbfe584709ac025304253", "6bbc6ce3a82591579a436536d8e16499eb19b7fc53901c0dc0d6727fba18548b"},
	{"psk-5", "ab447fa442c3eaf6f1cf3f87cf08167f1e2c73f97d3377284697961f7034ad9a", 358449, "aa4cb097610f1bf82b951a5849d8565ac5c198b776caa3ed2a44669a0d52dbdf", "a249ba971e76a4babc122974997a1fa7418c2183809ab2ae9b8dcb7a1da8776f"},
	{"psk-6", "14a9b9aa36c2efcb8a9ed74f4fb2894c15768c64e119a77e491d2101aff0a03d", 358378, "fe872498e42138c2ce8b5015229819184f3fc09b9418a3d443f1ed119f1407c2", "ab79acc9058fec693ed2a73b532f24cee0053564d6071fbf543e3e5ba7d86664"},
	{"psk-7", "cd54bcda209f4232bf615f5b7123c0e8c6a785c114b20b8027124e828477ccc7", 359285, "60c8a766173a04a8e2f5211222da38985eddabfd8355ee952111a0dc77771bbe", "cf413b4e34aae0b445ba8922e75667015b9011b9684317cadb03e14d05cdc4b2"},
	{"psk-8", "09c33d70d8660103d944a0ca9f7c45f9cf1107ef014790a6f0edd70f354d7a36", 356341, "42cfabcd05fceca0e3019b6056d5c83603dd80f67f86e7642208641dcd2a8df0", "ede69a88aa13d05b1dccafafe245eb658c62dedaad853b7148979faf2f7e112a"},
	{"psk-9", "8e8b074d995dbbcb1a4b4cca05198803d0c0b4a6eecd70ccc31d4e22d437f2aa", 356699, "8bd0872658e35bd7dc9cb34770a52a92c97d82b0fe261748aff0e1e0684acc0f", "a3a9def8486705cc0b9e58d4eca9e039b62a732e4e9d2c900a1fc41baa3fb7ed"},
	{"psk-10", "a680181ed4b4a0fece721cd79a49e62b49143f6d8fc2c05fef6cca3ba1a77fad", 353163, "7a156e71e1ba9438475a5e4d6cfd5920e1dd1817da23a8c25cd90eddc32c534a", "5c9e9a0c15ed77aa0db819b0a76ec8f5c68b0ccc179f565a880eb6a8b11240b8"},
	{"psk-11", "714a259fb85668cc9ce0bdff4a4be38f3aedd9bc7c21bb607682793d93f750f3", 356861, "5698964de9f9d8e8095a80e22e2d08218091680bba22db1ad75b50c6903a0f4b", "802e0427c4daeea6000ad03b0c05c3d2536b854910ba82fa6756012fc110081d"},
	{"psk-12", "f7247278d769f30f7e8e20bdc912f4b30201f2b1c6da05d6b6c992d1e5c42a93", 354471, "621676067506a990aeba718abae1c1464090d0c4cb2e18b0773a7cc2d2c559b1", "56f18909a9baa36ad0bd8954e9b69342dda704b347b03b8001867864ebb1367a"},
	{"psk-13", "f213b38108f9758003393f620fde485a5c6c4214704a436e3c6e336ab1844c6c", 354314, "a4c2fb50cfb160dd69334021644952e1a6e3df702327b5731f5739aeae09e916", "ca44d700086715453458a5634d0b886c8a45dc48a38fd285d4a0a870e1fd3aac"},
	{"psk-14", "10a3fd9b44c0003cda03c40d56970f14407f8087fda18c9d691f2e51d79715e5", 356725, "ec6abf0554b5a22529d132b745dc9ee25fb3a5b863540cf1bdbacaf5e8a489a0", "cf08b9c32e7a7006d831186a0b29c304e4f13d241a66e943391f6182c42bf072"},
	{"psk-15", "9c49bb16b3bd0ac97908e121300d389c952ddfe277e1ba36b2bc2d343037c006", 363255, "a31b721a6189853d6aac649e5340abac7d7f82a5a4f1e3e867cedf72b83056c6", "e3433f72c036aee6490c4ad71d5786c0d9b95490ecec9b4112a539c63878e996"},
	{"psk-16", "8eaf12250dd91cb55c1bd1ad7fdc082e6784a07eec161b4f7f2c1dad3a06d72a", 356087, "b8ff2a2d61a9edaa34c9ca82db4928fedfa11531f37dca31a97b5bba14f84ce4", "6a1b135a1aa4f1b2965242a576a0870be5c6d214d9dedb82e4f7ff43569d2435"},
}

func v6GoldenSeqs() []uint32 {
	var seqs []uint32
	for i := uint32(0); i < 48; i++ {
		seqs = append(seqs, i)
	}
	return append(seqs, 100, 1000, 65535, 65536, 0x7fffffff, 0xfffffffe, 0xffffffff)
}

func v6GoldenProfile(psk []byte) string {
	p := newV6Profile(psk)
	var b strings.Builder
	fmt.Fprintf(&b, "generator=%d padMin=%d padMax=%d padCount=%d padInterval=%d smallLimit=%d bitMin=%d bitMax=%d\n",
		p.generator, p.padMin, p.padMax, p.padCount, p.padInterval, p.smallLimit, p.bitMin, p.bitMax)
	fmt.Fprintf(&b, "prefixMinRecord=%d prefixMaxRecord=%d mixMode=%d mixRounds=%d mixStride=%d mixOffsetBase=%d mixBlock=%d\n",
		p.prefixMinRecord, p.prefixMaxRecord, p.mixMode, p.mixRounds, p.mixStride, p.mixOffsetBase, p.mixBlock)
	fmt.Fprintf(&b, "chunkPolicy=%d chunkInitial=%d firstRecordCap=%d chunkMax=%d chunkStep=%d chunkJitter=%d idleResetSec=%d\n",
		p.chunkPolicy, p.chunkInitial, p.firstRecordCap, p.chunkMax, p.chunkStep, p.chunkJitter, p.idleResetSec)
	fmt.Fprintf(&b, "writePolicy=%d writeFirst=%d chunkBuckets=%v writeBuckets=%v writeSeq=%v writeJitter=%d writeJitterPct=%d\n",
		p.writePolicy, p.writeFirst, p.chunkBuckets, p.writeBuckets, p.writeSeq, p.writeJitter, p.writeJitterPct)
	fmt.Fprintf(&b, "g=%d,%d,%d,%d,%d,%d saltBlockLen=%d mixStrideHS=%d mixRoundsHS=%d recordPrefixMax=%d padMaxHeadroom=%d\n",
		p.g1, p.g2, p.g3, p.g4, p.g5, p.g6, p.saltBlockLen, p.mixStrideHandshake, p.mixRoundsHandshake, p.recordPrefixMax, p.padMaxHeadroom)

	payloadLens := []int{0, 1, 2, 16, 95, 96, 97, 255, 256, 512, 767, 768, 769, 1000, 1400, 1459, 1460, 1461, 2000, 4096, 8192, 16383, 16384, 32768, 65535}
	for _, seq := range v6GoldenSeqs() {
		prefixLen := p.recordPrefixLen(seq)
		fmt.Fprintf(&b, "seq=%d prefix=%d pad=", seq, prefixLen)
		for _, payloadLen := range payloadLens {
			fmt.Fprintf(&b, "%d/%d,", p.paddingLen(seq, payloadLen, prefixLen, 0, 0),
				p.paddingLen(seq, payloadLen, prefixLen, p.saltBlockLen-v6SaltLen, p.saltBlockLen))
		}
		b.WriteString(" target=")
		for _, frameLen := range []int{1, 60, 200, 600, 1000, 1459, 1460, 1500, 65535, 70000} {
			fmt.Fprintf(&b, "%d,", p.writeTarget(seq, frameLen))
		}
		b.WriteString(" chunk=")
		for _, chunkSize := range []int{0, p.chunkInitial, 5000, p.chunkMax} {
			fmt.Fprintf(&b, "%d,", p.chunkPayloadLimit(seq, chunkSize))
		}
		b.WriteString("\n")
	}
	chunkSize := 0
	b.WriteString("chunks=")
	for i := uint32(0); i < 40; i++ {
		fmt.Fprintf(&b, "%d,", p.chunkPayloadLimit(i, chunkSize))
		chunkSize = p.nextChunkSize(chunkSize)
	}
	b.WriteString("\n")

	for _, seq := range []uint32{0, 1, 2, 3, 7, 100, 0xffffffff} {
		for _, n := range []int{1, 7, 16, 33, 128, 257, 1460, 4000} {
			output := bytes.Repeat([]byte{0xaa}, n)
			p.fillPadding(seq, output)
			sum := sha256.Sum256(output)
			fmt.Fprintf(&b, "fill seq=%d n=%d %s\n", seq, n, hex.EncodeToString(sum[:8]))
		}
	}

	salt := make([]byte, v6SaltLen)
	for i := range salt {
		salt[i] = byte(i*7 + 1)
	}
	block := make([]byte, p.saltBlockLen)
	p.fillPadding(0xffffffff, block)
	p.writeSaltBlock(salt, block)
	extracted := p.extractSalt(block)
	fmt.Fprintf(&b, "saltblock=%s extracted=%s\n", hex.EncodeToString(block), hex.EncodeToString(extracted[:]))

	for _, seq := range []uint32{0, 1, 2, 5, 100} {
		for _, lens := range [][2]int{{0, 40}, {24, 17}, {100, 100}, {300, 60}, {60, 300}, {730, 1476}, {1700, 16400}} {
			padding := make([]byte, lens[0])
			for i := range padding {
				padding[i] = byte(i*3 + 1)
			}
			payload := make([]byte, lens[1])
			for i := range payload {
				payload[i] = byte(i*5 + 2)
			}
			p.mixPaddingPayload(seq, padding, payload)
			hash := sha256.New()
			hash.Write(padding)
			hash.Write(payload)
			fmt.Fprintf(&b, "mix seq=%d %d/%d %s\n", seq, lens[0], lens[1], hex.EncodeToString(hash.Sum(nil)[:8]))
		}
	}
	return b.String()
}

func v6GoldenPayload(n int, seed int) []byte {
	payload := make([]byte, n)
	for i := range payload {
		payload[i] = byte(i*31 + seed)
	}
	return payload
}

// v6GoldenWire runs the fixed write script through the writer of the given
// mode with a fixed salt and returns everything it wrote.
func v6GoldenWire(t *testing.T, psk []byte, mode V6Mode) []byte {
	var salt [v6SaltLen]byte
	for i := range salt {
		salt[i] = byte(0x10 + i)
	}
	var profile *v6Profile
	if mode == V6ModeDefault {
		profile = newV6Profile(psk)
	}
	var out bytes.Buffer
	w, err := newV6RecordWriterWithSalt(&out, mode, psk, profile, salt)
	if err != nil {
		t.Fatal(err)
	}
	stream := func(n int, seed int) {
		if _, err := w.Write(v6GoldenPayload(n, seed)); err != nil {
			t.Fatal(err)
		}
	}
	packet := func(n int, seed int) {
		if err := w.writePacket(v6GoldenPayload(n, seed)); err != nil {
			t.Fatal(err)
		}
	}
	zero := func() {
		if err := w.writeZeroChunk(); err != nil {
			t.Fatal(err)
		}
	}
	stream(21, 1)
	stream(1, 2)
	stream(100, 3)
	stream(5000, 4)
	stream(70000, 5)
	packet(1200, 6)
	packet(1, 7)
	packet(65535, 8)
	zero()
	stream(300, 9)
	stream(200000, 10)
	zero()
	zero()
	return out.Bytes()
}

func TestSnellV6ProfileMatchesReference(t *testing.T) {
	for _, c := range v6GoldenCases {
		transcript := v6GoldenProfile([]byte(c.psk))
		// SNELL_V6_DUMP=1 prints the transcripts for a line-by-line diff
		// against the reference when a hash does not match.
		if os.Getenv("SNELL_V6_DUMP") != "" {
			fmt.Printf("### %s\n%s", c.psk, transcript)
		}
		sum := sha256.Sum256([]byte(transcript))
		if got := hex.EncodeToString(sum[:]); got != c.profile {
			t.Errorf("psk %q: profile transcript %s, want %s", c.psk, got, c.profile)
		}
	}
}

func TestSnellV6WireMatchesReference(t *testing.T) {
	check := func(psk string, mode V6Mode, wantLen int, wantSum string) {
		wire := v6GoldenWire(t, []byte(psk), mode)
		sum := sha256.Sum256(wire)
		if got := hex.EncodeToString(sum[:]); len(wire) != wantLen || got != wantSum {
			t.Errorf("psk %q mode %s: wrote %d bytes %s, want %d bytes %s", psk, mode, len(wire), got, wantLen, wantSum)
		}
	}
	for _, c := range v6GoldenCases {
		check(c.psk, V6ModeDefault, c.shapedLen, c.shapedWire)
		check(c.psk, V6ModeUnshaped, v6GoldenUnshapedLen, c.unshapedSum)
	}
	check(v6GoldenCases[0].psk, V6ModeUnsafeRaw, v6GoldenRawLen, v6GoldenRawSum)
}
