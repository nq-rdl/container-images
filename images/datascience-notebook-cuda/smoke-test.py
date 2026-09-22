"""Check the installed stack; --gpu also exercises the host's CDI device."""

import argparse
import os

import jupyterlab
import numpy
import pandas
import scipy
import sklearn
import torch


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--gpu", action="store_true", help="require a working CUDA device")
args = parser.parse_args()

release = {}
with open("/etc/os-release", encoding="utf-8") as source:
    for line in source:
        key, separator, value = line.strip().partition("=")
        if separator:
            release[key] = value.strip('"')
assert release["ID"] == "rhel", release
assert release["VERSION_ID"].split(".")[0] == "9", release
assert "CONDA_OVERRIDE_CUDA" not in os.environ, "CUDA override must not leak into runtime"
assert torch.version.cuda == "12.6", torch.version.cuda
assert torch.backends.cudnn.is_available(), "cuDNN is missing"
assert torch.backends.cudnn.version(), "cuDNN could not be loaded"
assert torch.ones(3).sum().item() == 3
print(
    f"UBI9: JupyterLab {jupyterlab.__version__}, NumPy {numpy.__version__}, "
    f"pandas {pandas.__version__}, SciPy {scipy.__version__}, "
    f"scikit-learn {sklearn.__version__}, PyTorch {torch.__version__}, "
    f"CUDA {torch.version.cuda}, cuDNN {torch.backends.cudnn.version()}"
)

if args.gpu:
    assert torch.cuda.is_available(), "No working CUDA device; check host driver and CDI"
    values = torch.arange(16, dtype=torch.float32, device="cuda").reshape(4, 4)
    torch.testing.assert_close((values @ values).cpu(), values.cpu() @ values.cpu())
    # Exercise cuDNN as well as CUDA tensor allocation and cuBLAS matrix multiplication.
    convolution = torch.nn.Conv2d(1, 2, 3).cuda()
    result = convolution(torch.ones((1, 1, 8, 8), device="cuda"))
    assert result.shape == (1, 2, 6, 6)
    assert torch.isfinite(result).all().item()
    torch.cuda.synchronize()
    print(f"GPU smoke passed: {torch.cuda.get_device_name(0)}")
else:
    print("Stack smoke passed; GPU execution was not requested")
