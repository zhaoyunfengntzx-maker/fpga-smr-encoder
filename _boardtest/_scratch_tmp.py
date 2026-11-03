from PIL import Image
im = Image.open(r'_disp_work\page_p1.png').convert('RGB')
im.crop((0,240,1024,420)).resize((1024,180)).save(r'_disp_work\_crop_card2.png')
im.crop((520,430,1024,600)).save(r'_disp_work\_crop_card6.png')
im.crop((60,50,560,240)).save(r'_disp_work\_crop_card1.png')
