# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0

from setuptools import setup

setup(
    name="sigver",
    license="Apache-2.0",
    python_requires=">=3.8",
    install_requires=[
        "azure-identity",
        "azure-keyvault-certificates",
        "azure-keyvault-keys",
    ],
    py_modules=["sha256tree", "sign", "verify"],
    entry_points={
        "console_scripts": [
            "sign=sign:main",
            "verify=verify:main",
        ]
    },
)
