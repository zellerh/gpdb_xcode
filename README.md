# gpdb_xcode
Files to make XCode work with the gpdb source tree

Run the following commands (on MacOS) in your top-level gpdb directory:

```
wget https://raw.githubusercontent.com/zellerh/gpdb_xcode/master/CMakeLists.txt
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer/

rm -rf build.xcode
mkdir build.xcode
cd build.xcode
cmake -GXcode -DCMAKE_BUILD_TYPE=Debug  ../
open gpdb.xcodeproj/

sudo xcode-select -s /Library/Developer/CommandLineTools
```
