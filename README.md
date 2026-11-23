# Mapfolio

Mapfolio is a personal map collection for iPhone. Save maps you find, align them to Apple Maps, and compare them with the modern basemap.

- Browse four historical city maps in a gallery or grid. Each layer can be hidden, translucent, or opaque.
- Press and hold the map to see the modern basemap without any overlays. Release to restore your layers.
- Import a map from Photos. Drag, pinch, and rotate it to place it, then optionally match landmarks with alignment pins. Saved map images and tiles stay on the device.
- Use the location button to show your current position. Mapfolio requests location only while in use and does not record or upload your location.

The Shanghai map is translucent on first launch; the other three are hidden. Use **View Map Sheet** to move the map to a sheet's extent.

## Build and test

Open [Mapfolio.xcodeproj](Mapfolio.xcodeproj) in Xcode and run the **Mapfolio** scheme on an iPhone simulator. To run on an iPhone, select your own team under **Signing & Capabilities**. Use an Xcode version with the iOS 27.1 SDK or newer to build the iPhone Duo toolbar code.

```sh
xcodebuild -project Mapfolio.xcodeproj -scheme Mapfolio \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Mapfolio is for exploring historical maps, not for navigation. Historical alignment can be approximate and has not been verified on-site in Shanghai.

## Map sources

| Map | Source and georeferencing |
| --- | --- |
| Detailed Street Map of Shanghai (1946) | [Stanford Libraries](https://purl.stanford.edu/df634mk1844), georeferenced by the Virtual Shanghai Project; Public Domain Mark 1.0. |
| Complete Detailed Map of Beiping (1930) | [Library of Congress, Geography and Map Division](https://www.loc.gov/item/2006458554/), originally published by Wenya Press; aligned using [Allmaps control points](https://annotations.allmaps.org/maps/2b97fc19f1edeabb). |
| Plan of Paris & Its Twelve Arrondissements (1811) | Reproduction courtesy of the [Norman B. Leventhal Map & Education Center at the Boston Public Library](https://collections.leventhalmap.org/search/commonwealth:3f4631174); aligned using [Allmaps control points](https://annotations.allmaps.org/maps/46c227d88b9276af). |
| Plan of the Cities of London & Westminster (c. 1765) | Reproduction courtesy of the [Norman B. Leventhal Map & Education Center at the Boston Public Library](https://collections.leventhalmap.org/search/commonwealth:3f462x782); aligned using [Allmaps control points](https://annotations.allmaps.org/maps/732ccb9e294a656f). |

Historical scans retain their original printed labels, borders, and insets. Insets are not aligned with the modern basemap.

The Shanghai and Beiping sheets include alternate tiles for the mainland China basemap. Mapfolio uses MapKit results for fixed public landmarks to choose a display profile, caches the last confirmed result, and defaults to source coordinates when no result is available. The offsets apply only to these historical overlays; they are not a general coordinate conversion.

## Rebuild the bundled tiles

The source scans are not included. Download `ID_341.tif` from [Stanford](https://stacks.stanford.edu/file/druid:df634mk1844/ID_341.tif). For the other three sheets, see the source image URLs and control points in [allmaps_specs.json](scripts/allmaps_specs.json). The scripts use [uv](https://docs.astral.sh/uv/) and check input file hashes.

```sh
uv run scripts/build_tiles.py /tmp/ID_341.tif Mapfolio/Resources/Shanghai1946.sqlite
uv run scripts/build_tiles.py /tmp/ID_341.tif Mapfolio/Resources/Shanghai1946Mainland.sqlite --profile mainland

uv run scripts/build_allmaps_tiles.py beijing1930 /tmp/beijing1930.jpg Mapfolio/Resources/Beijing1930.sqlite
uv run scripts/build_allmaps_tiles.py beijing1930 /tmp/beijing1930.jpg Mapfolio/Resources/Beijing1930Mainland.sqlite --profile mainland
uv run scripts/build_allmaps_tiles.py paris1811 /tmp/paris1811.jpg Mapfolio/Resources/Paris1811.sqlite
uv run scripts/build_allmaps_tiles.py london1765 /tmp/london1765.jpg Mapfolio/Resources/London1765.sqlite
```
