// resize.go — 512px 아이콘을 256px 로 축소 (go-winres 입력 제한 대응, 1회성 도구)
package main

import (
	"image"
	"image/png"
	"os"

	"golang.org/x/image/draw"
)

func main() {
	in, _ := os.Open(os.Args[1])
	src, _, err := image.Decode(in)
	if err != nil {
		panic(err)
	}
	in.Close()
	dst := image.NewRGBA(image.Rect(0, 0, 256, 256))
	draw.NearestNeighbor.Scale(dst, dst.Bounds(), src, src.Bounds(), draw.Over, nil)
	out, _ := os.Create(os.Args[2])
	defer out.Close()
	if err := png.Encode(out, dst); err != nil {
		panic(err)
	}
}
