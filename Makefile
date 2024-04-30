all: _build/Build/Products/Release/voxd

release: all

	 
_build/Build/Products/Release/voxd:
	xcodebuild -project voxd.xcodeproj -configuration Release -scheme voxd -derivedDataPath _build build

clean:
	rm -rf _build
