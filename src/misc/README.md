# mORMot Miscellaneous Units

## Folder Content

This folder contains some additional units supplied with the *mORMot* Open Source framework, version 2.

You will find in this folder some reusable code which is too specific to be in the `core` folder, but not specific to any ORM/SOA/MVC high-level features of the framework.

## Units Presentation

### mormot.misc.iso

*ISO 9660* File System Reader, as used for optical disc media
- Low-Level *ISO 9660* Encoding Structures
- High-Level `.iso` File Reader

Warning: this unit is just in early draft state - nothing works yet. ;)

### mormot.misc.pecoff

*PE COFF* File Reader, as used for windows executables or libraries (.exe, .dll)
- Low-Level PE Encoding Structures  
- High-Level PE (.exe, .dll...) File Reader
- Windows Executable Digital Signature Stuffing
