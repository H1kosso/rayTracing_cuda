#pragma once
#include <glm/glm.hpp>
#include "Ray.h"

struct Material {
	glm::vec4 color;
	float roughness;

	Material(glm::vec4 color, float roughness): color(color), roughness(roughness){};
	Material() : color(0.5f), roughness(0.f){};
};

class Hittable {
public:
	const enum class Hit {
		NO_HIT = -1
	};
protected:
	Hittable(glm::vec3 position, int matIdx) : position(position), materialIndex(matIdx) {}
	glm::vec3 position;
	
	int materialIndex;
};
