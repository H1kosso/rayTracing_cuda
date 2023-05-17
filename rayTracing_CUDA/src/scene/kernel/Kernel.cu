#include "Kernel.h"

static __global__ void init_curand(curandStatePhilox4_32_10_t* states, const glm::uvec2 imgDim) {
	uint32_t x = threadIdx.x + blockIdx.x * blockDim.x;
	uint32_t y = threadIdx.y + blockIdx.y * blockDim.y;
	uint32_t gIndex = x + y * blockDim.x * gridDim.x;

	if (imgDim.x <= x || imgDim.y <= y || imgDim.x * imgDim.y <= gIndex) {
		return;
	}
	curand_init((size_t)gIndex, 0, 0, &states[gIndex]);
	// Sequence 0 and offset 0 for better performance but may result in worse 'randomness'
}

static __global__ void trace_ray(
	uint32_t* imgBuff,
	const glm::uvec2 imgDim,
	curandStatePhilox4_32_10_t* rndState,
	const Sphere* hittable,
	const uint32_t hittableSize) {

	uint32_t x = threadIdx.x + blockIdx.x * blockDim.x;
	uint32_t y = threadIdx.y + blockIdx.y * blockDim.y;
	uint32_t gIndex = x + y * blockDim.x * gridDim.x;

	if (imgDim.x <= x || imgDim.y <= y || imgDim.x * imgDim.y <= gIndex) {
		return;
	}
	glm::vec2 coord = { ((float)x * 2.f / (float)imgDim.x) - 1.f, ((float)y * 2.f / (float)imgDim.y) - 1.f}; // [-1; 1]

	float grad = 0.5f * (-coord.y + 1.f);
	glm::vec4 backgroundColor = { (1.f - grad) * glm::vec3(1.f, 1.f, 1.f) + grad * glm::vec3(0.5f, 0.7f, 1.0f), 1.f};

	if (!hittableSize) {
		imgBuff[gIndex] = convertFromRGBA(backgroundColor);
		return;
	}

	Ray ray;
	ray.origin = { 0.f, 0.f, 1.f };
	ray.direction = glm::normalize(glm::vec3(coord.x, coord.y, -1.f));

	const Sphere* closestSphere = nullptr;
	glm::vec3 closestShiftOrigin{};
	float closestT{FLT_MAX};

	for (int i = 0; i < hittableSize; i++) {
		// Shifing current camera to the position of given object. It's used for the calculation of intersections.
		glm::vec3 shiftOrigin = ray.origin - hittable[i].getPosition();
		float t = hittable[i].hit({ shiftOrigin, ray.direction });
		if (t < 0.f)
			continue;

		if (t < closestT) {
			closestSphere = &hittable[i];
			closestT = t;
			closestShiftOrigin = shiftOrigin;
		}
	}

	if (closestSphere == nullptr) {
		imgBuff[gIndex] = convertFromRGBA(backgroundColor);
		return;
	}

	float randUniform = curand_uniform(&rndState[gIndex]);

	glm::vec3 closestHit = closestT * ray.direction + closestShiftOrigin;
	glm::vec3 normal = glm::normalize(closestHit); // normal as unit vector of closestHit

	glm::vec3 lightSource = glm::normalize(glm::vec3(1.f, 1.f, -1.f));
	float lightIntensity = glm::max(glm::dot(normal, -lightSource), 0.f); // only angles: 0 <= d <= 90

	imgBuff[gIndex] = convertFromRGBA(
		{
			closestSphere->getColor().r * lightIntensity,
			closestSphere->getColor().g * lightIntensity,
			closestSphere->getColor().b * lightIntensity,
			closestSphere->getColor().a 
		});
	// d_imgBuff[gIndex] = convertFromRGBA(closestSphere->getColor() * lightIntensity);
}

Kernel::Kernel(): kernelTimeMs(0.f), TPB(16){
}

void Kernel::runKernel(Scene& scene) {
	// TODO: Je�li to b�dzie w p�tli si� od�wie�a�o to warto nie alokowa� tego za ka�dym razem
	uint32_t* d_buffer = nullptr;
	Sphere* d_hittable = nullptr;
	uint32_t bufferSize = imgDim.x * imgDim.y;
	cudaEvent_t start, stop;
	curandStatePhilox4_32_10_t* d_curandState = nullptr;

	dim3 gridDim((imgDim.x + TPB - 1) / TPB, (imgDim.y + TPB - 1) / TPB);
	dim3 blockDim(TPB, TPB);

	cudaEventCreate(&start);
	cudaEventCreate(&stop);
	if (!bufferSize){
		throw std::invalid_argument("CUDA: buffer size is not set!");
	}
	else if (!buffer) {
		throw std::invalid_argument("CUDA: buffer is NULL!");
	}

	gpuErrChk(cudaMalloc(&d_buffer,  bufferSize * sizeof(*d_buffer)));
	gpuErrChk(cudaMalloc(&d_hittable, scene.sphere.size() * sizeof(*d_hittable)));
	gpuErrChk(cudaMalloc(&d_curandState, bufferSize * sizeof(*d_curandState)));

	gpuErrChk(cudaMemcpy(d_buffer, buffer, bufferSize * sizeof(*d_buffer), cudaMemcpyHostToDevice));
	gpuErrChk(cudaMemcpy(d_hittable, scene.sphere.data(), scene.sphere.size() * sizeof(*d_hittable), cudaMemcpyHostToDevice));

	/*
	gpuErrChk(cudaMalloc(&d_randomData, bufferSize * sizeof(*d_randomData)));
	// Create cuda random generator
	gpuCuRandErrChk(curandCreateGenerator(&cudaGen, CURAND_RNG_PSEUDO_MTGP32));

	// Set seed
	gpuCuRandErrChk(curandSetPseudoRandomGeneratorSeed(cudaGen, 13579ULL));

	// Generate random values from uniform distribution on device
	gpuCuRandErrChk(curandGenerateUniform(cudaGen, d_randomData, bufferSize));
	gpuErrChk(cudaDeviceSynchronize());
	*/
	cudaEventRecord(start);
	init_curand << < gridDim, blockDim >> > (d_curandState, imgDim);
	gpuErrChk(cudaDeviceSynchronize());

	trace_ray << < gridDim, blockDim >> > (d_buffer, imgDim, d_curandState, d_hittable, scene.sphere.size());
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&kernelTimeMs, start, stop);
	gpuErrChk(cudaGetLastError());

	gpuErrChk(cudaMemcpy(buffer, d_buffer, bufferSize * sizeof(*d_buffer), cudaMemcpyDeviceToHost));

	gpuErrChk(cudaFree(d_buffer));
	gpuErrChk(cudaFree(d_hittable));
	gpuErrChk(cudaFree(d_curandState));
	
	/*gpuErrChk(cudaFree(d_randomData));
	gpuCuRandErrChk(curandDestroyGenerator(cudaGen));*/
}

float Kernel::getKernelTimeMs()
{
	return kernelTimeMs;
}

Kernel::~Kernel() {}

void Kernel::setImgDim(glm::uvec2 imgDim){
	this->imgDim = imgDim;
}

void Kernel::setBuffer(uint32_t* buffer)
{
	this->buffer = buffer;
}
