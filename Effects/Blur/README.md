## Disclaimer

This script is maximally verbose and very ugly with all of the shader code written as gdscript strings and every single shader and pipeline individually compiled and constructed. This makes it very easy to share because otherwise it'd be like 10 different files. In the future this will be refactored using a more sophisticated shader compiler and memory manager, but right now, hopefully this communicates how ugly your own code might look without the privilege of abstractions.

# Image Blurs

This script contains implementations of the following blurs:

* Separated Box Blur
* Separated Gaussian Blur
* Kawase Blur
* Downscale/Upscale Blur
* Dual Kawase Blur

</br>

There are also two experimental blurs that are **not to be used**:
* Unseparated Race Condition Box Blur
* Unseparated Gaussian Blur

## Sources

Here are some valuable learning resources related to image blurs: <br>
<br> https://en.wikipedia.org/wiki/Gaussian_blur
<br> https://community.arm.com/cfs-file/__key/communityserver-blogs-components-weblogfiles/00-00-00-20-66/siggraph2015_2D00_mmg_2D00_marius_2D00_notes.pdf
<br> https://blog.frost.kiwi/dual-kawase/