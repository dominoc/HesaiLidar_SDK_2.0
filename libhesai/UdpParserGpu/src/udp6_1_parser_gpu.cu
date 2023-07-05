/*
[Hesai Technology Co., Ltd.] ("COMPANY") CONFIDENTIAL
Copyright (C) 2021 Hesai Technology Co., Ltd. All Rights Reserved.

NOTICE: All information contained herein is, and remains the property of
COMPANY. The intellectual and technical concepts contained herein are
proprietary to COMPANY and may be covered by Chinese and/or Foreign Patents,
patents in process, and are protected by trade secret and applicable
copyright laws. Dissemination of this information or reproduction of this
material is strictly forbidden unless prior written permission is obtained
from COMPANY. Access to the source code contained herein is hereby forbidden
to anyone except current COMPANY employees, managers or other third parties
who have executed Confidentiality and Non-disclosure agreements explicitly
covering such access.

The copyright notice above does not evidence any actual or intended
publication or disclosure of this source code, which includes information
that is confidential and/or proprietary, and is a trade secret, of COMPANY.

ANY REPRODUCTION, MODIFICATION, DISTRIBUTION, PUBLIC PERFORMANCE, OR PUBLIC
DISPLAY OF OR THROUGH USE OF THIS SOURCE CODE WITHOUT THE EXPRESS WRITTEN
CONSENT OF COMPANY IS STRICTLY PROHIBITED, AND IN VIOLATION OF APPLICABLE
LAWS AND INTERNATIONAL TREATIES. THE RECEIPT OR POSSESSION OF THIS SOURCE
CODE AND/OR RELATED INFORMATION DOES NOT CONVEY OR IMPLY ANY RIGHTS TO
REPRODUCE, DISCLOSE OR DISTRIBUTE ITS CONTENTS, OR TO MANUFACTURE, USE, OR
SELL ANYTHING THAT IT MAY DESCRIBE, IN WHOLE OR IN PART.
*/

#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include <cuda_device_runtime_api.h>
#include "udp6_1_parser_gpu.h"
#include "safe_call.cuh"
#include "return_code.h"

using namespace hesai::lidar;
template <typename T_Point>
Udp6_1ParserGpu<T_Point>::Udp6_1ParserGpu() {
  corrections_loaded_ = false;
  cudaSafeMalloc(raw_azimuths_cu_, sizeof(PointCloudStruct<T_Point>::azimuths));
  cudaSafeMalloc(raw_distances_cu_, sizeof(PointCloudStruct<T_Point>::distances));
  cudaSafeMalloc(raw_reflectivities_cu_, sizeof(PointCloudStruct<T_Point>::reflectivities));
  cudaSafeMalloc(raw_sensor_timestamp_cu_, sizeof(PointCloudStruct<T_Point>::sensor_timestamp));
}
template <typename T_Point>
Udp6_1ParserGpu<T_Point>::~Udp6_1ParserGpu() {
  cudaSafeFree(raw_azimuths_cu_);
  cudaSafeFree(raw_distances_cu_);
  cudaSafeFree(raw_reflectivities_cu_);
  if (corrections_loaded_) {
    cudaSafeFree(channel_elevations_cu_);
    cudaSafeFree(channel_azimuths_cu_);
    corrections_loaded_ = false;
  }
}
template <typename T_Point>
__global__ void compute_xyzs_6_1_impl(T_Point *xyzs, const float* channel_azimuths, const float* channel_elevations,
    const float* raw_azimuths, const uint16_t *raw_distances, const uint8_t *raw_reflectivities, 
    const uint64_t *raw_sensor_timestamp, const double raw_distance_unit, Transform transform, 
    int blocknum, int lasernum) {
  auto iscan = blockIdx.x;
  auto ichannel = threadIdx.x;
  float azimuth = raw_azimuths[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))];
  auto theta = ((azimuth + channel_azimuths[(ichannel % lasernum)] * kResolutionInt)) / HALF_CIRCLE * M_PI;
  float aziDelt = channel_azimuths[(ichannel % lasernum)] * kResolutionInt / HALF_CIRCLE * M_PI;
  auto phi = (channel_elevations[(ichannel % lasernum)] * kResolutionInt) / HALF_CIRCLE * M_PI;
  auto rho = raw_distances[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))] * raw_distance_unit;
  
  float x = 0.0f, y = 0.0f, z = 0.0f, r = 0.0f;
  float b_, h_;
  float aziCal = (int((azimuth + aziDelt) * HALF_CIRCLE / M_PI) % CIRCLE) / HALF_CIRCLE * M_PI;
  if (rho <= 0.1) {
    r = rho * cos(phi);
    x = r * sin(aziCal);
    y = r * cos(aziCal);
    z = rho * sin(phi);
  } else {
    switch (blocknum)
    {
    //XTM
    case 6: 
      b_ = 0.0130;
      h_ = 0.0305;
      break;
    //XT
    case 8: 
      b_ = 0.0130;
      h_ = 0.0315;
      break;

    default:
       printf("default: never occur%d\n", blocknum);
      break;
    }
    float aziCorrection = (int(aziDelt * HALF_CIRCLE / M_PI) % CIRCLE) / HALF_CIRCLE * M_PI;
    float calDistance = rho - cos(phi) * (h_ * cos(aziCorrection) - b_ * sin(aziCorrection));
    x = calDistance * cos(phi) * sin(aziCal) - b_ * cos(azimuth) + h_ * sin(azimuth);
    y = calDistance * cos(phi) * cos(aziCal) + b_ * sin(azimuth) + h_ * cos(azimuth);
    z = calDistance * sin(phi);
  }
  
  z = rho * sin(phi);
  r = rho * cosf(phi);
  x = r * sin(theta);
  y = r * cos(theta);

  float cosa = std::cos(transform.roll);
  float sina = std::sin(transform.roll);
  float cosb = std::cos(transform.pitch);
  float sinb = std::sin(transform.pitch);
  float cosc = std::cos(transform.yaw);
  float sinc = std::sin(transform.yaw);

  float x_ = cosb * cosc * x + (sina * sinb * cosc - cosa * sinc) * y +
              (sina * sinc + cosa * sinb * cosc) * z + transform.x;
  float y_ = cosb * sinc * x + (cosa * cosc + sina * sinb * sinc) * y +
              (cosa * sinb * sinc - sina * cosc) * z + transform.y;
  float z_ = -sinb * x + sina * cosb * y + cosa * cosb * z + transform.z;
  gpu::setX(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))], x_);
  gpu::setY(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))],  y_);
  gpu::setZ(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))], z_);
  gpu::setIntensity(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))], raw_reflectivities[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))]);
  gpu::setTimestamp(xyzs[iscan * blocknum * lasernum + (ichannel % (lasernum * blocknum))], double(raw_sensor_timestamp[iscan]) / kMicrosecondToSecond);
}
template <typename T_Point>
int Udp6_1ParserGpu<T_Point>::ComputeXYZI(LidarDecodedFrame<T_Point> &frame) {
  cudaSafeCall(cudaMemcpy(raw_azimuths_cu_, frame.azimuth,
                          kMaxPacketNumPerFrame * kMaxPointsNumPerPacket * sizeof(float), cudaMemcpyHostToDevice),
               ReturnCode::CudaMemcpyHostToDeviceError);
  cudaSafeCall(cudaMemcpy(raw_distances_cu_, frame.distances,
                          kMaxPacketNumPerFrame * kMaxPointsNumPerPacket * sizeof(uint16_t),
                          cudaMemcpyHostToDevice),
               ReturnCode::CudaMemcpyHostToDeviceError); 
  cudaSafeCall(cudaMemcpy(raw_reflectivities_cu_, frame.reflectivities,
                          kMaxPacketNumPerFrame * kMaxPointsNumPerPacket * sizeof(uint8_t),
                          cudaMemcpyHostToDevice),
               ReturnCode::CudaMemcpyHostToDeviceError);  
  cudaSafeCall(cudaMemcpy(raw_sensor_timestamp_cu_, frame.sensor_timestamp,
                          kMaxPacketNumPerFrame * sizeof(uint64_t),
                          cudaMemcpyHostToDevice),
               ReturnCode::CudaMemcpyHostToDeviceError);    
compute_xyzs_6_1_impl<<<kMaxPacketNumPerFrame, kMaxPointsNumPerPacket>>>(this->frame_.gpu()->points, channel_azimuths_cu_, channel_elevations_cu_, 
                                                        raw_azimuths_cu_, raw_distances_cu_, raw_reflectivities_cu_, raw_sensor_timestamp_cu_, frame.distance_unit, this->transform_, frame.block_num, frame.laser_num);
  cudaSafeCall(cudaGetLastError(), ReturnCode::CudaXYZComputingError);
  this->frame_.DeviceToHost();
  std::memcpy(frame.points, this->frame_.cpu()->points, sizeof(T_Point) * kMaxPacketNumPerFrame * kMaxPointsNumPerPacket);
  return 0;
}
template <typename T_Point>
int Udp6_1ParserGpu<T_Point>::LoadCorrectionString(char *correction_content) {
  if (corrections_loaded_) {
    return 0;
    if (channel_elevations_cu_) cudaFree(channel_elevations_cu_);
    if (channel_azimuths_cu_) cudaFree(channel_azimuths_cu_);
    corrections_loaded_ = false;
  }
  std::string correction_content_str = correction_content;
  std::istringstream ifs(correction_content_str);
  std::string line;
  // skip first line "Laser id,Elevation,Azimuth" or "eeff"
  std::getline(ifs, line);  

  float elevation_list[MAX_LASER_NUM], azimuth_list[MAX_LASER_NUM];

  std::vector<std::string> vfirstLine;
  boost::split(vfirstLine, line, boost::is_any_of(","));
  if (vfirstLine[0] == "EEFF" || vfirstLine[0] == "eeff") {
    // skip second line
    std::getline(ifs, line);  
  }

  int lineCount = 0;
  while (std::getline(ifs, line)) {
    std::vector<std::string> vLineSplit;
    boost::split(vLineSplit, line, boost::is_any_of(","));
    // skip error line or hash value line
    if (vLineSplit.size() < 3) {  
      continue;
    } else {
      lineCount++;
    }
    float elevation, azimuth;
    int laserId = 0;

    std::stringstream ss(line);
    std::string subline;
    std::getline(ss, subline, ',');
    std::stringstream(subline) >> laserId;
    std::getline(ss, subline, ',');
    std::stringstream(subline) >> elevation;
    std::getline(ss, subline, ',');
    std::stringstream(subline) >> azimuth;

    if (laserId != lineCount || laserId >= MAX_LASER_NUM) {
      std::cout << "laser id is wrong in correction file. laser Id:"
                  << laserId << ", line" << lineCount << std::endl;
      return -1;
    }
    elevation_list[laserId - 1] = elevation;
    azimuth_list[laserId - 1] = azimuth;
}
  CUDACheck(cudaMalloc(&channel_azimuths_cu_, sizeof(float) * MAX_LASER_NUM));
  CUDACheck(cudaMalloc(&channel_elevations_cu_, sizeof(float) * MAX_LASER_NUM));
  CUDACheck(cudaMemcpy(channel_azimuths_cu_, azimuth_list, sizeof(float) * MAX_LASER_NUM, cudaMemcpyHostToDevice));
  CUDACheck(cudaMemcpy(channel_elevations_cu_, elevation_list, sizeof(float) * MAX_LASER_NUM, cudaMemcpyHostToDevice));
  corrections_loaded_ = true;
  return 0;
}
template <typename T_Point>
int Udp6_1ParserGpu<T_Point>::LoadCorrectionFile(std::string lidar_correction_file) {
  int ret = 0;
  printf("load correction file from local correction.csv now!\n");
  std::ifstream fin(lidar_correction_file);
  if (fin.is_open()) {
    printf("Open correction file success\n");
    int length = 0;
    std::string str_lidar_calibration;
    fin.seekg(0, std::ios::end);
    length = fin.tellg();
    fin.seekg(0, std::ios::beg);
    char *buffer = new char[length];
    fin.read(buffer, length);
    fin.close();
    str_lidar_calibration = buffer;
    ret = LoadCorrectionString(buffer);
    if (ret != 0) {
      printf("Parse local Correction file Error\n");
    } else {
      printf("Parse local Correction file Success!!!\n");
      return 0;
    }
  } else {
    printf("Open correction file failed\n");
    return -1;
  }
  return -1;
}
