#include "GpuSim.h"

#include "ldpMat\ldp_basic_mat.h"
#include "cudpp\thrust_wrapper.h"
#include "cudpp\CachedDeviceBuffer.h"
#include <math.h>
namespace ldp
{
#pragma region --utils
	enum{
		CTA_SIZE = 512,
		CTA_SIZE_X = 32,
		CTA_SIZE_Y = 16
	};

#define CHECK_ZERO(a){if(a)printf("!!!error: %s=%d\n", #a, a);}

	typedef ldp_basic_vec<float, 9> Float9;
	typedef ldp_basic_vec<float, 12> FloatC;
	typedef ldp_basic_mat_sqr<float, 9> Mat9f;
	typedef ldp_basic_mat_sqr<float, 12> MatCf;
	typedef ldp_basic_mat<float, 3, 2> Mat32f;
	typedef ldp_basic_mat<float, 3, 9> Mat39f;
	typedef ldp_basic_mat<float, 2, 3> Mat23f;
	typedef ldp_basic_mat_col<float, 3> Mat31f;
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

	template<int N, int M>
	__device__ __host__ __forceinline__ ldp_basic_vec<float, M> mat_getRow(ldp_basic_mat<float, N, M> A, int row)
	{
		ldp_basic_vec<float, M> x;
		for (int k = 0; k < M; k++)
			x[k] = A(row, k);
		return x;
	}
	template<int N, int M>
	__device__ __host__ __forceinline__ ldp_basic_vec<float, N> mat_getCol(ldp_basic_mat<float, N, M> A, int col)
	{
		ldp_basic_vec<float, N> x;
		for (int k = 0; k < N; k++)
			x[k] = A(k, col);
		return x;
	}
	template<int N, int M>
	__device__ __host__ __forceinline__ ldp_basic_mat<float, N, M> outer(
		ldp::ldp_basic_vec<float, N> x, ldp::ldp_basic_vec<float, M> y)
	{
		ldp_basic_mat<float, N, M> A;
		for (int row = 0; row < N; row++)
		for (int col = 0; col < M; col++)
			A(row, col) = x[row] * y[col];
		return A;
	}
	template<class T, int N>
	__device__ __host__ __forceinline__ T sum(ldp::ldp_basic_vec<T, N> x)
	{
		T s = T(0);
		for (int i = 0; i < N; i++)
			s += x[i];
		return s;
	}


	__device__ __host__ __forceinline__ Float9 make_Float9(Float3 a, Float3 b, Float3 c)
	{
		Float9 d;
		for (int k = 0; k < 3; k++)
		{
			d[k] = a[k];
			d[3 + k] = b[k];
			d[6 + k] = c[k];
		}
		return d;
	}
	__device__ __host__ __forceinline__ FloatC make_Float12(Float3 a, Float3 b, Float3 c, Float3 d)
	{
		FloatC v;
		for (int k = 0; k < 4; k++)
		{
			v[k] = a[k];
			v[3 + k] = b[k];
			d[6 + k] = c[k];
			v[9 + k] = d[k];
		}
		return v;
	}
	__device__ __host__ __forceinline__ Mat32f derivative(const Float3 x[3], const Float2 t[3])
	{
		return Mat32f(Mat31f(x[1] - x[0]), Mat31f(x[2] - x[0])) * Mat2f(t[1] - t[0], t[2] - t[0]).inv();
	}
	__device__ __host__ __forceinline__ Mat23f derivative(const Float2 t[3])
	{
		return Mat2f(t[1] - t[0], t[2] - t[0]).inv()*
			Mat32f(Mat31f(Float3(-1, 1, 0)), Mat31f(Float3(-1, 0, 1))).trans();
	}
	__device__ __host__ __forceinline__ float faceArea(const Float2 t[3])
	{
		return fabs(Float2(t[1]-t[0]).cross(t[2]-t[0])) * 0.5f;
	}
	__device__ __host__ __forceinline__ Float3 faceNormal(const Float3 t[3])
	{
		Float3 n = Float3(t[1] - t[0]).cross(t[2] - t[0]);
		if (n.length() == 0.f)
			return 0.f;
		return n.normalizeLocal();
	}
	__device__ __host__ __forceinline__ float faceArea(const Float3 t[3])
	{
		return Float3(t[1] - t[0]).cross(t[2] - t[0]).length() * 0.5f;
	}
	
	__device__ __host__ __forceinline__ Float3 get_subFloat3(Float9 a, int i)
	{
		return Float3(a[i*3], a[i*3+1], a[i*3+2]);
	}
	__device__ __host__ __forceinline__ Mat3f get_subMat3f(Mat9f A, int row, int col)
	{
		Mat3f B;
		for (int r = 0; r < 3; r++)
		for (int c = 0; c < 3; c++)
			B(r, c) = A(r+row*3, c+col*3);
		return B;
	}

	__device__ __host__ __forceinline__ Float3 get_subFloat3(FloatC a, int i)
	{
		return Float3(a[i * 3], a[i * 3 + 1], a[i * 3 + 2]);
	}
	__device__ __host__ __forceinline__ Mat3f get_subMat3f(MatCf A, int row, int col)
	{
		Mat3f B;
		for (int r = 0; r < 3; r++)
		for (int c = 0; c < 3; c++)
			B(r, c) = A(r + row * 3, c + col * 3);
		return B;
	}
	__device__ __host__ __forceinline__ float unwrap_angle(float theta, float theta_ref)
	{
		if (theta - theta_ref > M_PI)
			theta -= 2 * M_PI;
		if (theta - theta_ref < -M_PI)
			theta += 2 * M_PI;
		return theta;
	}

	template<class T>
	static cudaTextureObject_t createTexture(DeviceArray2D<T>& ary, cudaTextureFilterMode filterMode)
	{
		cudaResourceDesc texRes;
		memset(&texRes, 0, sizeof(cudaResourceDesc));
		texRes.resType = cudaResourceTypePitch2D;
		texRes.res.pitch2D.height = ary.rows();
		texRes.res.pitch2D.width = ary.cols();
		texRes.res.pitch2D.pitchInBytes = ary.step();
		texRes.res.pitch2D.desc = cudaCreateChannelDesc<T>();
		texRes.res.pitch2D.devPtr = ary.ptr();
		cudaTextureDesc texDescr;
		memset(&texDescr, 0, sizeof(cudaTextureDesc));
		texDescr.normalizedCoords = 0;
		texDescr.filterMode = filterMode;
		texDescr.addressMode[0] = cudaAddressModeClamp;
		texDescr.addressMode[1] = cudaAddressModeClamp;
		texDescr.addressMode[2] = cudaAddressModeClamp;
		texDescr.readMode = cudaReadModeElementType;
		cudaTextureObject_t tex;
		cudaSafeCall(cudaCreateTextureObject(&tex, &texRes, &texDescr, NULL));
		return tex;
	}

	template<class T>
	static cudaTextureObject_t createTexture(DeviceArray<T>& ary, cudaTextureFilterMode filterMode)
	{
		cudaResourceDesc texRes;
		memset(&texRes, 0, sizeof(cudaResourceDesc));
		texRes.resType = cudaResourceTypeLinear;
		texRes.res.linear.sizeInBytes = ary.sizeBytes();
		texRes.res.pitch2D.desc = cudaCreateChannelDesc<T>();
		texRes.res.pitch2D.devPtr = ary.ptr();
		cudaTextureDesc texDescr;
		memset(&texDescr, 0, sizeof(cudaTextureDesc));
		texDescr.normalizedCoords = 0;
		texDescr.filterMode = filterMode;
		texDescr.addressMode[0] = cudaAddressModeClamp;
		texDescr.addressMode[1] = cudaAddressModeClamp;
		texDescr.addressMode[2] = cudaAddressModeClamp;
		texDescr.readMode = cudaReadModeElementType;
		cudaTextureObject_t tex;
		cudaSafeCall(cudaCreateTextureObject(&tex, &texRes, &texDescr, NULL));
		return tex;
	}

#pragma endregion

#pragma region -- vert pair <--> idx
	__global__ void vertPair_to_idx_kernel(const int* v1, const int* v2, size_t* ids, int nVerts, int nPairs)
	{
		int i = threadIdx.x + blockIdx.x * blockDim.x;
		if (i < nPairs)
			ids[i] = vertPair_to_idx(ldp::Int2(v1[i], v2[i]), nVerts);
	}
	__global__ void vertPair_from_idx_kernel(int* v1, int* v2, const size_t* ids, int nVerts, int nPairs)
	{
		int i = threadIdx.x + blockIdx.x * blockDim.x;
		if (i < nPairs)
		{
			ldp::Int2 vert = vertPair_from_idx(ids[i], nVerts);
			v1[i] = vert[0];
			v2[i] = vert[1];
		}
	}

	void GpuSim::vertPair_to_idx(const int* v1, const int* v2, size_t* ids, int nVerts, int nPairs)
	{
		vertPair_to_idx_kernel << <divUp(nPairs, CTA_SIZE), CTA_SIZE >> >(
			v1, v2, ids, nVerts, nPairs);
		cudaSafeCall(cudaGetLastError());
	}

	void GpuSim::vertPair_from_idx(int* v1, int* v2, const size_t* ids, int nVerts, int nPairs)
	{
		vertPair_from_idx_kernel << <divUp(nPairs, CTA_SIZE), CTA_SIZE >> >(
			v1, v2, ids, nVerts, nPairs);
		cudaSafeCall(cudaGetLastError());
	}
#pragma endregion

#pragma region --update numeric
	texture<float, cudaTextureType1D, cudaReadModeElementType> gt_x;
	texture<float, cudaTextureType1D, cudaReadModeElementType> gt_x_init;
	texture<float2, cudaTextureType1D, cudaReadModeElementType> gt_texCoord_init;
	texture<int4, cudaTextureType1D, cudaReadModeElementType> gt_faces_idxWorld;
	texture<int4, cudaTextureType1D, cudaReadModeElementType> gt_faces_idxTex;
	texture<int, cudaTextureType1D, cudaReadModeElementType> gt_A_order;
	texture<int, cudaTextureType1D, cudaReadModeElementType> gt_b_order;
	__device__ __forceinline__ Float3 texRead_x(int i)
	{
		return ldp::Float3(tex1Dfetch(gt_x, i * 3), 
			tex1Dfetch(gt_x, i * 3 + 1), tex1Dfetch(gt_x, i * 3 + 2));
	}
	__device__ __forceinline__ Float3 texRead_x_init(int i)
	{
		return ldp::Float3(tex1Dfetch(gt_x_init, i * 3),
			tex1Dfetch(gt_x_init, i * 3 + 1), tex1Dfetch(gt_x_init, i * 3 + 2));
	}
	__device__ __forceinline__ Float2 texRead_texCoord_init(int i)
	{
		float2 a = tex1Dfetch(gt_texCoord_init, i);
		return ldp::Float2(a.x, a.y);
	}
	__device__ __forceinline__ Int3 texRead_faces_idxWorld(int i)
	{
		int4 a = tex1Dfetch(gt_faces_idxWorld, i);
		return ldp::Int3(a.x, a.y, a.z);
	}
	__device__ __forceinline__ Int3 texRead_faces_idxTex(int i)
	{
		int4 a = tex1Dfetch(gt_faces_idxTex, i);
		return ldp::Int3(a.x, a.y, a.z);
	}
	__device__ __forceinline__ int texRead_A_order(int i)
	{
		return tex1Dfetch(gt_A_order, i);
	}
	__device__ __forceinline__ int texRead_b_order(int i)
	{
		return tex1Dfetch(gt_b_order, i);
	}
	__device__ __forceinline__ Float4 texRead_strechSample(cudaTextureObject_t t, float x, float y, float z)
	{
		float4 v = tex3D<float4>(t, x, y, z);
		return ldp::Float4(v.x, v.y, v.z, v.w);
	}
	__device__ __forceinline__ float texRead_bendData(cudaTextureObject_t t, float x, float y)
	{
		return tex2D<float>(t, x, y);
	}
	__device__ __forceinline__ float distance(const Float3 &x, const Float3 &a, const Float3 &b)
	{
		Float3 e = b - a;
		Float3 xp = e*e.dot(x - a) / e.dot(e);
		return max((x - a - xp).length(), 1e-3f*e.length());
	}
	__device__ __forceinline__ Float2 barycentric_weights(Float3 x, Float3 a, Float3 b)
	{
		double t = (b-a).dot(x - a) / (b-a).sqrLength();
		return Float2(1 - t, t);
	}

	void GpuSim::bindTextures()
	{
		size_t offset;
		cudaChannelFormatDesc desc_float = cudaCreateChannelDesc<float>();
		cudaChannelFormatDesc desc_float2 = cudaCreateChannelDesc<float2>();
		cudaChannelFormatDesc desc_int = cudaCreateChannelDesc<int>();
		cudaChannelFormatDesc desc_int4 = cudaCreateChannelDesc<int4>();

		cudaSafeCall(cudaBindTexture(&offset, &gt_x, m_x.ptr(), 
			&desc_float, m_x.size()*sizeof(float3)));
		CHECK_ZERO(offset);

		cudaSafeCall(cudaBindTexture(&offset, &gt_x_init, m_x_init.ptr(),
			&desc_float, m_x_init.size()*sizeof(float3)));
		CHECK_ZERO(offset);

		cudaSafeCall(cudaBindTexture(&offset, &gt_texCoord_init, m_texCoord_init.ptr(), 
			&desc_float2, m_texCoord_init.size()*sizeof(float2)));
		CHECK_ZERO(offset);

		cudaSafeCall(cudaBindTexture(&offset, &gt_faces_idxWorld, m_faces_idxWorld_d.ptr(),
			&desc_int4, m_faces_idxWorld_d.size()*sizeof(int4)));
		CHECK_ZERO(offset);

		cudaSafeCall(cudaBindTexture(&offset, &gt_faces_idxTex, m_faces_idxTex_d.ptr(),
			&desc_int4, m_faces_idxTex_d.size()*sizeof(int4)));
		CHECK_ZERO(offset);

		cudaSafeCall(cudaBindTexture(&offset, &gt_A_order, m_A_order_d.ptr(),
			&desc_int, m_A_order_d.size()*sizeof(int)));
		CHECK_ZERO(offset);

		cudaSafeCall(cudaBindTexture(&offset, &gt_b_order, m_b_order_d.ptr(),
			&desc_int, m_b_order_d.size()*sizeof(int)));
		CHECK_ZERO(offset);
	}


	__device__ __forceinline__ Float4 stretching_stiffness(const Mat2f &G, cudaTextureObject_t samples)
	{
		float a = (G(0, 0) + 0.25f)*GpuSim::StretchingSamples::SAMPLES;
		float b = (G(1, 1) + 0.25f)*GpuSim::StretchingSamples::SAMPLES;
		float c = fabsf(G(0, 1))*GpuSim::StretchingSamples::SAMPLES;
		return texRead_strechSample(samples, a, b, c);
	}

	__device__ __forceinline__ float bending_stiffness(Float3 a, Float3 b, 
		Float2 ta, Float2 tb, float theta, float area,
		cudaTextureObject_t bendData, float initial_theta)
	{
		// because samples are per 0.05 cm^-1 = 5 m^-1
		float value = theta*(a - b).length() / area * 0.5f*0.2f; 
		if (value > 4) 
			value = 4;
		int value_i = (int)value;
		if (value_i<0)   
			value_i = 0;
		if (value_i>3)   
			value_i = 3;
		value -= value_i;

		const Float2 du = tb - ta;
		float bias_angle = (atan2f(du[1], du[0]) + initial_theta) * 4.f / M_PI;
		if (bias_angle<0)        
			bias_angle = -bias_angle;
		if (bias_angle>4)        
			bias_angle = 8 - bias_angle;
		if (bias_angle > 2)        
			bias_angle = 4 - bias_angle;
		int bias_id = (int)bias_angle;
		if (bias_id<0)   
			bias_id = 0;
		if (bias_id>1)   
			bias_id = 1;
		bias_angle -= bias_id;
		float actual_ke = texRead_bendData(bendData, value_i, bias_id) * (1 - bias_angle)*(1 - value)
			+ texRead_bendData(bendData + 1, value_i, bias_id) * (bias_angle)*(1 - value)
			+ texRead_bendData(bendData, value_i, bias_id + 1) * (1 - bias_angle)*(value)
			+texRead_bendData(bendData, value_i + 1, bias_id + 1) * (bias_angle)*(value);
		if (actual_ke < 0) actual_ke = 0;
		return actual_ke;
	}

	__device__ __host__ __forceinline__  Mat39f kronecker_eye_row(const Mat23f &A, int iRow)
	{
		Mat39f C;
		C.zeros();
		for (int k = 0; k < 3; k++)
		{
			C(k, k) = A(iRow, k);
			C(k, k + 3) = A(iRow, k);
			C(k, k + 6) = A(iRow, k);
		}
		return C;
	}

	__device__ __host__ __forceinline__  float dihedral_angle(
		Float3 a, Float3 b, Float3 n0, Float3 n1, float ref_theta)
	{
		if ((a - b).length() == 0.f || n0.length() == 0.f || n1.length() == 0.f)
			return 0.f;
		Float3 e = (a - b).normalize();
		double cosine = n0.dot(n1), sine = e.dot(n0.cross(n1));
		double theta = atan2(sine, cosine);
		return unwrap_angle(theta, ref_theta);
	}

	__device__ void computeStretchForces(int iFace, 
		int A_start, Mat3f* beforeScan_A,
		int b_start, Float3* beforeScan_b,
		const cudaTextureObject_t* t_stretchSamples, float dt)
	{
		const ldp::Int3 face_idxWorld = texRead_faces_idxWorld(iFace);
		const ldp::Int3 face_idxTex = texRead_faces_idxTex(iFace);
		const ldp::Float3 x[3] = { texRead_x(face_idxWorld[0]), texRead_x(face_idxWorld[1]),
			texRead_x(face_idxWorld[2]) };
		const ldp::Float2 t[3] = { texRead_texCoord_init(face_idxTex[0]),
			texRead_texCoord_init(face_idxTex[1]), texRead_texCoord_init(face_idxTex[2]) };
		const float area = faceArea(t);

		// arcsim::stretching_force()---------------------------
		const Mat32f F = derivative(x, t);
		const Mat2f G = (F.trans()*F - Mat2f().eye()) * 0.5f;
		const Float4 k = stretching_stiffness(G, t_stretchSamples[iFace]);
		const Mat23f D = derivative(t);
		const Mat39f Du = kronecker_eye_row(D, 0);
		const Mat39f Dv = kronecker_eye_row(D, 1);
		const Float3 xu = mat_getCol(F, 0);
		const Float3 xv = mat_getCol(F, 1); // should equal Du*mat_to_vec(X)
		const Float9 fuu = Du.trans()*xu;
		const Float9 fvv = Dv.trans()*xv;
		const Float9 fuv = (Du.trans()*xv + Dv.trans()*xu) * 0.5f;
		Float9 grad_e = k[0] * G(0, 0)*fuu + k[2] * G(1, 1)*fvv
			+ k[1] * (G(0, 0)*fvv + G(1, 1)*fuu) + 2 * k[3] * G(0, 1)*fuv;
		Mat9f hess_e = k[0] * (outer(fuu, fuu) + max(G(0, 0), 0.f)*Du.trans()*Du)
			+ k[2] * (outer(fvv, fvv) + max(G(1, 1), 0.f)*Dv.trans()*Dv)
			+ k[1] * (outer(fuu, fvv) + max(G(0, 0), 0.f)*Dv.trans()*Dv
			+ outer(fvv, fuu) + max(G(1, 1), 0.f)*Du.trans()*Du)
			+ 2.*k[3] * (outer(fuv, fuv));

		const Float9 vs = make_Float9(x[0], x[1], x[2]);
		hess_e = (dt*dt*area) * hess_e;
		grad_e = -area * dt * grad_e + hess_e*vs;

		// output to global matrix
		for (int row = 0; row < 3; row++)
		for (int col = 0; col < 3; col++)
		{
			int pos = texRead_A_order(A_start + row * 3 + col);
			beforeScan_A[pos] = get_subMat3f(hess_e, row, col);
		} // end for row, col

		for (int row = 0; row < 3; row++)
		{
			int pos = texRead_b_order(b_start + row);
			beforeScan_b[pos] = get_subFloat3(grad_e, row);
		} // end for row
	}

	__device__ void computeBendForces(int iEdge, const GpuSim::EdgeData* edgeDatas,
		int A_start, Mat3f* beforeScan_A,
		int b_start, Float3* beforeScan_b, 
		const cudaTextureObject_t* t_bendDatas, 
		const float* theta_refs, float dt)
	{
		const GpuSim::EdgeData edgeData = edgeDatas[iEdge];
		if (edgeData.faceIdx[0] < 0 || edgeData.faceIdx[1] < 0)
			return;

		const ldp::Int3 face_idxWorld[2] = {
			texRead_faces_idxWorld(edgeData.faceIdx[0]),
			texRead_faces_idxWorld(edgeData.faceIdx[1]),
		};
		const ldp::Int3 face_idxTex[2] = {
			texRead_faces_idxTex(edgeData.faceIdx[0]),
			texRead_faces_idxTex(edgeData.faceIdx[1]),
		};		
		const ldp::Float3 x[2][3] = { 
			{ texRead_x(face_idxWorld[0][0]), texRead_x(face_idxWorld[0][1]), texRead_x(face_idxWorld[0][2]) },
			{ texRead_x(face_idxWorld[1][0]), texRead_x(face_idxWorld[1][1]), texRead_x(face_idxWorld[1][2]) },
		};
		const ldp::Float2 t[2][3] = {
			{ texRead_texCoord_init(face_idxWorld[0][0]), texRead_texCoord_init(face_idxWorld[0][1]), 
			texRead_texCoord_init(face_idxWorld[0][2]) },
			{ texRead_texCoord_init(face_idxWorld[1][0]), texRead_texCoord_init(face_idxWorld[1][1]), 
			texRead_texCoord_init(face_idxWorld[1][2]) },
		};
		const ldp::Int4 eIds(edgeData.edge_idxWorld[0], edgeData.edge_idxWorld[1],
			sum(face_idxWorld[0]) - edgeData.edge_idxWorld[0] - edgeData.edge_idxWorld[1],
			sum(face_idxWorld[1]) - edgeData.edge_idxWorld[0] - edgeData.edge_idxWorld[1]
			);
		const ldp::Float3 ex[4] = { texRead_x(eIds[0]), texRead_x(eIds[1]), texRead_x(eIds[2]), texRead_x(eIds[3]) };
		const ldp::Float2 et[2] = { texRead_texCoord_init(eIds[0]), texRead_texCoord_init(eIds[1])};
		Float3 n0 = faceNormal(x[0]), n1 = faceNormal(x[1]);
		const float area = faceArea(t[0]) + faceArea(t[0]);
		const float theta_ref = theta_refs[iEdge];
		const float theta = dihedral_angle(ex[0], ex[1], n0, n1, theta_ref);
		const float h0 = distance(ex[2], ex[0], ex[1]), h1 = distance(ex[3], ex[0], ex[1]);
		const Float2 w_f0 = barycentric_weights(ex[2], ex[0], ex[1]);
		const Float2 w_f1 = barycentric_weights(ex[3], ex[0], ex[1]);
		const FloatC dtheta = make_Float12(-(w_f0[0] * n0 / h0 + w_f1[0] * n1 / h1),
			-(w_f0[1] * n0 / h0 + w_f1[1] * n1 / h1), n0 / h0, n1 / h1);
		const float ke = min(bending_stiffness(
			ex[0], ex[1], et[0], et[1], theta, area,
			t_bendDatas[edgeData.faceIdx[0]], theta_ref),
			bending_stiffness(ex[0], ex[1], et[0], et[1], theta, area,
			t_bendDatas[edgeData.faceIdx[1]], theta_ref)
			);
		const float shape = (ex[0]-ex[1]).sqrLength() / (2.f * area);
		const FloatC vs = make_Float12(ex[0], ex[1], ex[2], ex[3]);
		FloatC F = -dt*0.5f * ke*shape*(theta - theta_ref)*dtheta;
		MatCf J = -dt*dt*0.5f*ke*shape*outer(dtheta, dtheta);
		F -= J*vs;

		// output to global matrix
		for (int row = 0; row < 4; row++)
		for (int col = 0; col < 4; col++)
		{
			int pos = texRead_A_order(A_start + row * 4 + col);
			beforeScan_A[pos] = get_subMat3f(J, row, col);
		} // end for row, col

		for (int row = 0; row < 4; row++)
		{
			int pos = texRead_b_order(b_start + row);
			beforeScan_b[pos] = get_subFloat3(F, row);
		} // end for row
	}

	__global__ void computeNumeric_kernel(const GpuSim::EdgeData* edgeData, 
		const cudaTextureObject_t* t_stretchSamples, const cudaTextureObject_t* t_bendDatas,
		const int* A_starts, Mat3f* beforeScan_A, 
		const int* b_starts, Float3* beforeScan_b,
		const float* theta_refs,
		int nFaces, int nEdges, float dt)
	{
		int thread_id = threadIdx.x + blockIdx.x * blockDim.x;

		// compute stretching forces here
		if (thread_id < nFaces)
		{
			const int A_start = A_starts[thread_id];
			const int b_start = b_starts[thread_id];
			const ldp::Int3 face_idxWorld = texRead_faces_idxWorld(thread_id);
			computeStretchForces(thread_id, A_start, beforeScan_A, 
				b_start, beforeScan_b, t_stretchSamples, dt);
		} // end if nFaces_numAb
		// compute bending forces here
		else if (thread_id < nFaces + nEdges)
		{
			const int A_start = A_starts[thread_id];
			const int b_start = b_starts[thread_id];
			computeBendForces(thread_id - nFaces, edgeData, A_start, beforeScan_A,
				b_start, beforeScan_b, t_bendDatas, theta_refs, dt);
		}
	}

	void GpuSim::updateNumeric()
	{
		const int nFaces = m_faces_idxWorld_d.size();
		const int nEdges = m_edgeData_d.size();
	
		computeNumeric_kernel << <divUp(nFaces + nEdges, CTA_SIZE), CTA_SIZE >> >(
			m_edgeData_d.ptr(), m_faces_texStretch_d.ptr(), m_faces_texBend_d.ptr(),
			m_A_Ids_start_d.ptr(), m_beforScan_A.ptr(),
			m_b_Ids_start_d.ptr(), m_beforScan_b.ptr(),
			m_edgeThetaIdeals_d.ptr(),
			nFaces, nEdges, m_simParam.dt);
		cudaSafeCall(cudaGetLastError());
	}
#pragma endregion
}