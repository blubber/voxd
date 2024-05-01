all: _build/Build/Products/Release/voxd

release: all
	mkdir -p dist/{bin,share}
	cp _build/Build/Products/Release/voxd dist/bin
	cp voxd.json.example dist/share
	tar -cf dist/voxd-$(VOXD_VERSION).tar.gz -C dist/ bin share
	 
_build/Build/Products/Release/voxd:
	xcodebuild -project voxd.xcodeproj -configuration Release -scheme voxd -derivedDataPath _build build

clean:
	rm -rf _build dist
