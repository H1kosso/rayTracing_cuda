#pragma once
#include "../kernel/Kernel.h"
#include "../scene/Scene.h"
#include "Walnut/Image.h"

#include <memory>

class Render {
public:
	Render();
	void onResize(uint32_t nImgWidth, uint32_t nImgHeight);
	void render(Scene& scene);
	float getRednderTimeMs();
	std::shared_ptr<Walnut::Image> getFinalImage();

	~Render();
private:
	Kernel kernel;
	uint32_t imageWidth = 0, imageHeight = 0;
	uint32_t* imageBuffer = nullptr;
	std::shared_ptr<Walnut::Image> image;

	void reallocateImageBuffer(uint32_t x, uint32_t y);
};